// FlvSplicer.swift
// HAo Live — FLV lease splicer, re-implemented from wzgrx/PureLive v4
// (packages/live_media/lib/src/relay/flv_splicer.dart: FlvSplicer).
// mpv plays one local loopback URL; the splicer swaps the upstream
// underneath it at the lease's refreshAt, so the player is never
// reopened. Foundation only — no UIKit, no Network framework — so the
// Linux harness runs the real implementation.
//
// Threading contract: all splice state except the three task handles
// and the cancelled flag (guarded by `taskLock`) is owned by the task
// running `run()`. Reader, preparation and timer tasks never touch
// splice state directly; they deliver work to the run loop through
// the `SpliceMailbox` actor. `cancel()` is safe to call from any
// thread. The class is `@unchecked Sendable` on that contract.

import Foundation

/// Limits of one splice. Defaults copied verbatim from wzgrx's
/// `SpliceTimings` — do not retune them without checking the reference.
struct SpliceTimings: Sendable {
    /// Longest wait for the renewal callback (the refresh timeout).
    var renewTimeout: TimeInterval
    /// Longest wait for the new connection's header.
    var connectTimeout: TimeInterval
    /// Longest search for a usable keyframe on the new connection.
    var keyframeSearch: TimeInterval
    /// Longest wait for the old stream to reach the new keyframe.
    var handoverWait: TimeInterval
    /// Wait before another renewal attempt while the old connection
    /// still streams.
    var retryDelay: TimeInterval
    /// A new connection whose first video timestamp is further than
    /// this from the delivered position is on another timeline and
    /// gets shifted.
    var alignmentWindow: TimeInterval
    /// Step between the last delivered video tag and a shifted keyframe.
    var shiftGap: TimeInterval

    init(
        renewTimeout: TimeInterval = 12,
        connectTimeout: TimeInterval = 15,
        keyframeSearch: TimeInterval = 15,
        handoverWait: TimeInterval = 10,
        retryDelay: TimeInterval = 10,
        alignmentWindow: TimeInterval = 60,
        shiftGap: TimeInterval = 0.040
    ) {
        self.renewTimeout = renewTimeout
        self.connectTimeout = connectTimeout
        self.keyframeSearch = keyframeSearch
        self.handoverWait = handoverWait
        self.retryDelay = retryDelay
        self.alignmentWindow = alignmentWindow
        self.shiftGap = shiftGap
    }
}

/// Something the splicer did, for logs. `renewFailed` carries the error
/// description as a string (rather than the error itself) so the event
/// stays Sendable under Swift 6.
enum SpliceEvent: Sendable {
    /// A renewal started.
    case renewing(oldEnded: Bool)
    /// The output continued on a new connection.
    case switched(line: PlayStream, switchAt: Int, shifted: Bool, oldEnded: Bool, waitedForOld: TimeInterval)
    /// A renewal attempt failed; the old connection keeps streaming.
    case renewFailed(String)
    /// The spliced output ended.
    case ended(reason: String)
}

/// One upstream FLV connection as packets: the file header first, then
/// tags. `nil` means the connection ended (clean close, reset, idle
/// timeout or a framing error); the splicer decides what follows.
protocol FlvPacketSource: AnyObject, Sendable {
    /// The next packet, or `nil` once the connection ended.
    func next() async -> [UInt8]?
    /// Drops the connection.
    func cancel()
}

/// Opens an upstream connection for a line. The URL and signature
/// parameters are used verbatim; headers are passed through unchanged.
typealias FlvSourceOpener = @Sendable (PlayStream) async throws -> any FlvPacketSource

/// Resolves a fresh line for the same room, quality and line as the
/// current one (the service re-resolves and picks the same
/// quality+line, mirroring wzgrx's `selectRelayRenewal`).
typealias FlvLineRenewer = @Sendable (PlayStream) async throws -> PlayStream

/// Why a splice run failed.
enum FlvSplicerError: Error, Sendable {
    /// The first connection delivered no FLV header.
    case emptyUpstream
    /// The new connection ended before a keyframe.
    case newConnectionEnded
    /// No usable keyframe appeared on the new connection in time.
    case noKeyframe
    /// A step ran past its limit.
    case timeout
}

/// Routing for a line: whether it goes through the splicer, and when
/// its renewal starts. HAoLive's `PlayStream` has no `cutsConnection`
/// flag; `expiresAt != nil` is the marker that the signed URL's lease
/// will cut the connection (Douyu `expire`, Huya's 125 s transport
/// lease) — the same lines the service's lease timer already fires for.
enum FlvRelay {
    /// FLV + a lease + a renewer: splice renewals in. Anything else
    /// plays direct.
    static func shouldSplice(stream: PlayStream, canRenew: Bool) -> Bool {
        stream.format == "flv" && stream.expiresAt != nil && canRenew
    }

    /// The renewal instant for a line: 45 s before expiry, or a
    /// quarter of the lifetime for short leases — the same rule as
    /// `LivePlayerService.scheduleLeaseRefresh`.
    static func refreshAt(for stream: PlayStream, now: Date = Date()) -> Date? {
        guard let expiresAt = stream.expiresAt else { return nil }
        let lifetime = expiresAt.timeIntervalSince(now)
        guard lifetime > 0 else { return now }
        let lead = min(45, lifetime / 4)
        return expiresAt.addingTimeInterval(-lead)
    }
}

/// A renewal candidate: the new connection's first undelivered
/// keyframe, plus the configuration and audio seen before it.
private struct SpliceCandidate: Sendable {
    let line: PlayStream
    let source: any FlvPacketSource
    let keyframe: [UInt8]
    /// Same timeline as the delivered output: switch where the old
    /// stream reaches `switchAt`. Otherwise switch at once and shift.
    let aligned: Bool
    /// Output-timeline offset of the new connection's raw timestamps.
    let offset: Int
    let videoConfig: [UInt8]?
    let audioConfig: [UInt8]?
    let audioBefore: [[UInt8]]
    var readyAt: Date?

    var switchAt: Int { FlvTag.timestamp(of: keyframe) + offset }
}

/// The run loop's inbox. Producers (reader, preparation, timers) only
/// ever push; only the run loop pops.
private actor SpliceMailbox {
    enum Event {
        case packet(generation: Int, tag: [UInt8])
        case sourceEnded(generation: Int)
        case renewalDue
        case wake
        case candidateReady(SpliceCandidate)
        case candidateFailed
        case stopped
    }

    private var queue: [Event] = []
    private var waiters: [CheckedContinuation<Event?, Never>] = []

    func push(_ event: Event) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: event)
        } else {
            queue.append(event)
        }
    }

    func next() async -> Event? {
        if !queue.isEmpty { return queue.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func stop() {
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
}

private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            throw FlvSplicerError.timeout
        }
        guard let result = try await group.next() else { throw FlvSplicerError.timeout }
        group.cancelAll()
        return result
    }
}

/// Streams one continuous FLV from a line whose lease cuts the
/// connection, replacing the upstream URL underneath the player.
///
/// At the lease's `refreshAt` the renewed line is connected while the
/// old connection keeps being forwarded. The switch happens at the
/// first keyframe of the new connection that the old one has not
/// delivered: the old stream is forwarded up to that timestamp, then
/// the new one from its keyframe on, so the player sees one timestamp
/// timeline without gap or repeat. A new connection on another
/// timeline (more than 60 s away) is shifted to continue the delivered
/// one. Script tags are not repeated after a switch; codec
/// configurations are re-sent when they change. When the old
/// connection ends before a successor is ready, at most one GOP is
/// skipped; when no successor can be opened, the output ends and the
/// player's recovery takes over.
final class FlvSplicer: @unchecked Sendable {
    /// Limits.
    let timings: SpliceTimings

    private let open: FlvSourceOpener
    private let renew: FlvLineRenewer
    private let emit: ([UInt8]) -> Void
    private let onEvent: ((SpliceEvent) -> Void)?

    private let mailbox = SpliceMailbox()

    /// Guards `_cancelled` and the three task handles; everything else
    /// is run-loop-owned.
    private let taskLock = NSLock()
    private var _cancelled = false
    private var _renewTask: Task<Void, Never>?
    private var _preparingTask: Task<Void, Never>?
    private var _readerTask: Task<Void, Never>?

    // Run-loop-owned state.
    private var _line: PlayStream
    private var _source: (any FlvPacketSource)?
    private var _generation = 0
    private var _offset = 0
    private var _lastVideo: Int?
    private var _lastAudio: Int?
    private var _videoConfig: [UInt8]?
    private var _audioConfig: [UInt8]?
    private var _switches = 0
    private var _oldEnded = false
    private var _waitingForSuccessor = false
    private var _ready: SpliceCandidate?
    private var _preparing = false
    private var _scanning = false
    private var _holdUsed = false
    private var _held: [UInt8]?
    private var _holdUntil: Date?
    private var _pendingPackets: [[UInt8]] = []
    private var _started = false

    /// The line currently streaming. Only valid after `run()` returns
    /// (the relay owns the authoritative line while running).
    var line: PlayStream { _line }

    /// Completed switches.
    var switches: Int { _switches }

    /// Last delivered video timestamp (output timeline), if any.
    var lastVideoTimestamp: Int? { _lastVideo }

    /// Creates a splicer starting at `line`. `emit` receives the
    /// spliced packets (the FLV header first, then tags); `onEvent`
    /// receives splice events.
    init(
        line: PlayStream,
        open: @escaping FlvSourceOpener,
        renew: @escaping FlvLineRenewer,
        emit: @escaping ([UInt8]) -> Void,
        onEvent: ((SpliceEvent) -> Void)? = nil,
        timings: SpliceTimings = SpliceTimings()
    ) {
        self._line = line
        self.open = open
        self.renew = renew
        self.emit = emit
        self.onEvent = onEvent
        self.timings = timings
    }

    /// Runs until the output ends; throws when the first connection
    /// cannot be opened or is not FLV. Single-use.
    func run() async throws {
        guard !_started else { return }
        _started = true
        let first: any FlvPacketSource
        do {
            first = try await open(_line)
        } catch {
            teardown()
            throw error
        }
        if isCancelled() {
            first.cancel()
            teardown()
            return
        }
        _source = first
        startReader(for: first, generation: _generation)
        // The header comes through the mailbox: the reader is the only
        // consumer of source.next().
        var headerDone = false
        while !headerDone {
            guard let event = await mailbox.next() else {
                teardown()
                return
            }
            switch event {
            case .packet(_, let tag):
                emit(tag)
                headerDone = true
            case .sourceEnded(let generation):
                guard generation == _generation else { continue }
                teardown()
                throw FlvSplicerError.emptyUpstream
            case .stopped:
                teardown()
                return
            default:
                continue
            }
        }
        scheduleRenewal()
        mainLoop: while !isCancelled() {
            guard let event = await mailbox.next() else { break }
            if isCancelled() { break }
            switch event {
            case .stopped:
                break mainLoop
            case .renewalDue:
                startPreparing()
            case .wake:
                if let ready = _ready, (!ready.aligned || handoverExpired(ready)) {
                    switchTo(ready)
                    continue mainLoop
                }
                releaseHeldIfReady()
            case .candidateReady(var candidate):
                _preparing = false
                _scanning = false
                storePreparingTask(nil)
                if let last = _lastVideo, candidate.aligned, candidate.switchAt <= last {
                    // The old stream delivered the keyframe while the
                    // candidate was in flight; it is no longer usable.
                    candidate.source.cancel()
                    if _waitingForSuccessor {
                        onEvent?(.ended(reason: "successor keyframe already delivered"))
                        break mainLoop
                    }
                    scheduleRetry()
                } else {
                    candidate.readyAt = Date()
                    _ready = candidate
                    if _waitingForSuccessor || !candidate.aligned {
                        // The old connection is gone, or the new one is
                        // on another timeline: switch at once.
                        switchTo(candidate)
                    } else {
                        scheduleWake(after: timings.handoverWait)
                        releaseHeldIfReady()
                    }
                }
            case .candidateFailed:
                _preparing = false
                _scanning = false
                storePreparingTask(nil)
                releaseHeldIfReady()
                if _waitingForSuccessor {
                    onEvent?(.ended(reason: "upstream ended without a successor"))
                    break mainLoop
                }
                if !_oldEnded {
                    scheduleRetry()
                }
            case .packet(let generation, let tag):
                guard generation == _generation else { continue }
                if _held != nil {
                    if _ready == nil && _preparing && !holdExpired {
                        // Both connections sit at the live edge: keep
                        // stashing old packets until the hold releases.
                        _pendingPackets.append(tag)
                        continue
                    }
                    _pendingPackets.insert(tag, at: 0)
                    releaseHeldIfReady()
                    drainPending()
                    continue
                }
                processTag(tag)
            case .sourceEnded(let generation):
                guard generation == _generation else { continue }
                _oldEnded = true
                _held = nil
                _pendingPackets.removeAll()
                if let ready = _ready {
                    switchTo(ready)
                } else {
                    _waitingForSuccessor = true
                    cancelRenewTask()
                    if !_preparing {
                        startPreparing()
                    }
                }
            }
        }
        teardown()
    }

    /// Stops the output and drops every connection. Safe from any thread.
    func cancel() {
        taskLock.lock()
        if _cancelled {
            taskLock.unlock()
            return
        }
        _cancelled = true
        _renewTask?.cancel()
        _renewTask = nil
        _preparingTask?.cancel()
        _preparingTask = nil
        _readerTask?.cancel()
        _readerTask = nil
        taskLock.unlock()
        Task { await mailbox.push(.stopped) }
    }

    // MARK: - Run loop helpers

    private var holdExpired: Bool {
        guard let until = _holdUntil else { return true }
        return Date() >= until
    }

    private func handoverExpired(_ candidate: SpliceCandidate) -> Bool {
        guard let readyAt = candidate.readyAt else { return false }
        return Date().timeIntervalSince(readyAt) >= timings.handoverWait
    }

    private func isCancelled() -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return _cancelled
    }

    private func storeRenewTask(_ task: Task<Void, Never>?) {
        taskLock.lock()
        defer { taskLock.unlock() }
        _renewTask?.cancel()
        _renewTask = task
    }

    private func cancelRenewTask() {
        taskLock.lock()
        defer { taskLock.unlock() }
        _renewTask?.cancel()
        _renewTask = nil
    }

    private func storePreparingTask(_ task: Task<Void, Never>?) {
        taskLock.lock()
        defer { taskLock.unlock() }
        _preparingTask = task
    }

    private func storeReaderTask(_ task: Task<Void, Never>?) {
        taskLock.lock()
        defer { taskLock.unlock() }
        _readerTask?.cancel()
        _readerTask = task
    }

    private func takeReaderTask() -> Task<Void, Never>? {
        taskLock.lock()
        defer { taskLock.unlock() }
        let task = _readerTask
        _readerTask = nil
        return task
    }

    private func startReader(for source: any FlvPacketSource, generation: Int) {
        let task = Task {
            while let packet = await source.next() {
                await mailbox.push(.packet(generation: generation, tag: packet))
                if Task.isCancelled { break }
            }
            await mailbox.push(.sourceEnded(generation: generation))
        }
        storeReaderTask(task)
    }

    private func scheduleRenewal() {
        cancelRenewTask()
        guard let refreshAt = FlvRelay.refreshAt(for: _line) else { return }
        let delay = max(0, refreshAt.timeIntervalSinceNow)
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await mailbox.push(.renewalDue)
        }
        storeRenewTask(task)
    }

    private func scheduleRetry() {
        cancelRenewTask()
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(timings.retryDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await mailbox.push(.renewalDue)
        }
        storeRenewTask(task)
    }

    /// Fire-and-forget wake (hold / handover expiry). Stale wakes are
    /// harmless: every handler re-checks its condition.
    private func scheduleWake(after seconds: TimeInterval) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            await mailbox.push(.wake)
        }
    }

    private func startPreparing() {
        guard !isCancelled(), !_preparing, _ready == nil else { return }
        _holdUsed = false
        _preparing = true
        _scanning = true
        onEvent?(.renewing(oldEnded: _oldEnded))
        let line = _line
        let deliveredVideo = _lastVideo
        let offset = _offset
        let timings = timings
        let task = Task {
            let candidate = await self.prepare(
                line: line, deliveredVideo: deliveredVideo, offset: offset, timings: timings)
            if let candidate {
                await mailbox.push(.candidateReady(candidate))
            } else {
                await mailbox.push(.candidateFailed)
            }
        }
        storePreparingTask(task)
    }

    /// Opens the renewed line and scans it for the first keyframe the
    /// old stream has not delivered. Runs off the run loop; touches no
    /// splice state (snapshots are passed in).
    private func prepare(
        line: PlayStream,
        deliveredVideo: Int?,
        offset: Int,
        timings: SpliceTimings
    ) async -> SpliceCandidate? {
        var openedSource: (any FlvPacketSource)?
        do {
            let next = try await withTimeout(timings.renewTimeout) {
                try await self.renew(line)
            }
            if isCancelled() { return nil }
            let newSource = try await withTimeout(timings.connectTimeout) {
                try await self.open(next)
            }
            openedSource = newSource
            if isCancelled() {
                newSource.cancel()
                return nil
            }
            let scanSource = newSource
            let header = try await withTimeout(timings.connectTimeout) {
                await scanSource.next()
            }
            guard header != nil else { throw FlvSplicerError.emptyUpstream }
            let searchEnd = Date().addingTimeInterval(timings.keyframeSearch)
            var videoConfig: [UInt8]?
            var audioConfig: [UInt8]?
            var audioBefore: [[UInt8]] = []
            var aligned: Bool?
            var alignedOffset: Int?
            while true {
                let remaining = searchEnd.timeIntervalSinceNow
                guard remaining > 0 else { throw FlvSplicerError.noKeyframe }
                guard let tag = try await withTimeout(remaining, {
                    await scanSource.next()
                }) else {
                    throw FlvSplicerError.newConnectionEnded
                }
                if isCancelled() {
                    scanSource.cancel()
                    return nil
                }
                if FlvTag.isVideoConfig(tag) {
                    videoConfig = tag
                    continue
                }
                if FlvTag.isAudioConfig(tag) {
                    audioConfig = tag
                    continue
                }
                let type = FlvTag.type(of: tag)
                if type == FlvTag.audio {
                    audioBefore.append(tag)
                    if audioBefore.count > 256 { audioBefore.removeFirst() }
                    continue
                }
                if type != FlvTag.video { continue }
                let raw = FlvTag.timestamp(of: tag)
                if aligned == nil {
                    if let delivered = deliveredVideo {
                        aligned = abs(raw - (delivered - offset))
                            <= Int(timings.alignmentWindow * 1000)
                    } else {
                        aligned = true
                    }
                    if aligned == true { alignedOffset = offset }
                }
                guard FlvTag.isKeyframe(tag) else { continue }
                if aligned == true, let delivered = deliveredVideo,
                   let alignedOffset, raw + alignedOffset <= delivered {
                    continue
                }
                return SpliceCandidate(
                    line: next,
                    source: scanSource,
                    keyframe: tag,
                    aligned: aligned ?? false,
                    offset: alignedOffset ?? 0,
                    videoConfig: videoConfig,
                    audioConfig: audioConfig,
                    audioBefore: audioBefore
                )
            }
        } catch {
            openedSource?.cancel()
            if !isCancelled() {
                onEvent?(.renewFailed(String(describing: error)))
            }
            return nil
        }
    }

    private func switchTo(_ candidate: SpliceCandidate) {
        _ready = nil
        _waitingForSuccessor = false
        cancelRenewTask()
        let waited = candidate.readyAt.map { Date().timeIntervalSince($0) } ?? 0
        let oldSource = _source
        let oldReader = takeReaderTask()
        _source = candidate.source
        _generation += 1
        _held = nil
        _pendingPackets.removeAll()
        startReader(for: candidate.source, generation: _generation)
        oldReader?.cancel()
        oldSource?.cancel()
        let oldEnded = _oldEnded

        let keyRaw = FlvTag.timestamp(of: candidate.keyframe)
        var offset = candidate.offset
        if !candidate.aligned {
            offset = _lastVideo.map { $0 + Int(timings.shiftGap * 1000) - keyRaw } ?? 0
        }
        _offset = offset
        _line = candidate.line
        _switches += 1

        let lastAudio = _lastAudio
        let audio = candidate.audioBefore.filter {
            lastAudio == nil || FlvTag.timestamp(of: $0) + offset > lastAudio!
        }
        let firstTs = audio.first.map { FlvTag.timestamp(of: $0) } ?? keyRaw
        if let videoConfig = candidate.videoConfig,
           _videoConfig == nil || !FlvTag.samePayload(videoConfig, _videoConfig!) {
            forward(FlvTag.withTimestamp(videoConfig, keyRaw), offset: offset)
        }
        if let audioConfig = candidate.audioConfig,
           _audioConfig == nil || !FlvTag.samePayload(audioConfig, _audioConfig!) {
            forward(FlvTag.withTimestamp(audioConfig, firstTs), offset: offset)
        }
        for tag in audio {
            forward(tag, offset: offset)
        }
        forward(candidate.keyframe, offset: offset)
        onEvent?(.switched(
            line: candidate.line,
            switchAt: keyRaw + offset,
            shifted: !candidate.aligned,
            oldEnded: oldEnded,
            waitedForOld: waited
        ))
        _oldEnded = false
        scheduleRenewal()
    }

    /// One old-stream tag through the hold / switch checks, then forward.
    private func processTag(_ tag: [UInt8]) {
        if _ready == nil && _scanning && !_holdUsed && FlvTag.isKeyframe(tag) {
            // Both connections sit at the live edge, so the old one
            // would usually deliver the shared keyframe first and push
            // the switch to a later GOP (or past the cut). Hold the old
            // stream just before its keyframe until the new connection
            // reaches it.
            _held = tag
            _holdUsed = true
            _holdUntil = Date().addingTimeInterval(timings.handoverWait)
            scheduleWake(after: timings.handoverWait)
            return
        }
        if let current = _ready, current.aligned {
            let type = FlvTag.type(of: tag)
            let ts = FlvTag.timestamp(of: tag) + _offset
            if type == FlvTag.video && !FlvTag.isVideoConfig(tag) && ts >= current.switchAt {
                switchTo(current)
                return
            }
            if type == FlvTag.audio && !FlvTag.isAudioConfig(tag) && ts >= current.switchAt {
                return
            }
        }
        forward(tag, offset: _offset)
    }

    /// Releases the held keyframe once the renewal is decided (or the
    /// hold expired), then drains the packets stashed behind it.
    private func releaseHeldIfReady() {
        guard let heldTag = _held else { return }
        guard _ready != nil || !_preparing || holdExpired else { return }
        _held = nil
        processTag(heldTag)
        drainPending()
    }

    private func drainPending() {
        while !_pendingPackets.isEmpty {
            if _held != nil { return }
            let tag = _pendingPackets.removeFirst()
            processTag(tag)
        }
    }

    private func forward(_ tag: [UInt8], offset: Int) {
        let type = FlvTag.type(of: tag)
        if type == FlvTag.script {
            if _switches == 0 { emit(tag) }
            return
        }
        let ts = FlvTag.timestamp(of: tag) + offset
        if ts < 0 { return }
        if FlvTag.isVideoConfig(tag) {
            _videoConfig = tag
        } else if FlvTag.isAudioConfig(tag) {
            _audioConfig = tag
        } else if type == FlvTag.video {
            if let last = _lastVideo, ts < last { return }
            _lastVideo = ts
        } else if type == FlvTag.audio {
            if let last = _lastAudio, ts <= last { return }
            _lastAudio = ts
        }
        emit(offset == 0 ? tag : FlvTag.withTimestamp(tag, ts))
    }

    private func teardown() {
        taskLock.lock()
        _renewTask?.cancel()
        _renewTask = nil
        _preparingTask?.cancel()
        _preparingTask = nil
        _readerTask?.cancel()
        _readerTask = nil
        taskLock.unlock()
        _ready?.source.cancel()
        _ready = nil
        _source?.cancel()
        _source = nil
        _held = nil
        _pendingPackets.removeAll()
        Task { await mailbox.stop() }
    }
}
