// LivePlayerService.swift
// HAo Live — playback facade over the single mpv engine.
// wzgrx/PureLive v4 (chen 2026-11-28 designated it the
// reference; verified in the local clone, HEAD c0932e8):
// mpv is THE ONLY engine ("the only engine in v4",
// packages/live_player/lib/src/mpv_engine.dart:38) — no
// MediaKit/FlvLzc/BetterPlayer, no kernel switch in settings
// (KernelTile shows mpv and cannot be changed). chen 19:03
// also decided: no system player, only mpv. Build 9/10's
// HLS→system-player-first split is deleted, and the AVPlayer
// fallback is gone with it — AVPlayerEngine.swift is deleted.
// Sweep, translated to Swift: attempt(source) fails -> next
// source on the same engine -> sources exhausted -> re-resolve
// once, sweep the fresh list -> nothing left -> fail honestly.
// "Fails" means the engine reported a hard error, or no frame
// appeared within the source-ready timeout (8 s — Pure Live's
// rule: 8 s with no picture prompts a line switch; build 10's
// 18 s was wrong; the 8 s is live_status.dart's slowAfter).
// A presented-frame stall recreates the engine once (wzgrx
// recovery step 3): a fresh engine retries GL, and falls to
// the software renderer when GL cannot be built — so a dead
// GPU path never kills playback outright.
// Signed URLs have a lease: a Douyu FLV line carries
// `expire=300` — the CDN closes it 5 minutes after issuance —
// and a Huya web-template URL carries a 125 s transport lease
// (Pure Live's _transportInvalidAge), so the service refreshes
// the stream before the lease ends (Pure Live's
// getPlayUrlRefreshAt: 45 s before expiry, or a quarter of the
// lifetime for short leases), instead of letting the picture
// freeze mid-stream. Streams without a known expiry (patched ws
// lines, HLS) get no timer. A lease refresh re-resolves and
// switches on the SAME engine (Pure Live: switching quality/line
// does not rebuild the player) — only a missing match falls back
// to a full reopen. FLV lease renewals go through the session
// FLV splicer instead of a reopen — see FlvSplicer.swift
// (FlvSplicer + FlvRelay routing) and LoopbackRelay.swift (the
// 127.0.0.1 server mpv plays from); the refresh() below only
// runs for lines the splicer does not own.
// Before the next candidate, sources are re-resolved through
// sourceRefresh (Pure Live's onEngineFallbackSources: signed URLs
// are single-use, so a fresh resolve is needed per attempt).
//
// The service only reports .playing when an engine actually shows
// a picture. Tried streams are remembered for this open() only;
// a manual play / switch clears the memory first.

import Combine
import Foundation
import os
import UIKit

@MainActor
final class LivePlayerService: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    /// Pure Live's source-ready watchdog: 8 s with no picture
    /// means the attempt failed — prompt to switch lines (not
    /// the 18 s build 10 used; that number could not be verified
    /// in Pure Live at all).
    static let sourceReadyTimeout: TimeInterval = 8

    private let log = Logger(subsystem: "live.haostudio", category: "player")

    @Published private(set) var state: State = .idle
    @Published private(set) var currentStream: PlayStream?
    @Published private(set) var availableStreams: [PlayStream] = []
    @Published private(set) var engineName: String = "—"
    /// Visible notice while loading (e.g. the 8 s watchdog fired
    /// and the service switched lines). Cleared when a stream
    /// becomes ready. The room view shows this under the spinner.
    @Published private(set) var notice: String?

    /// The one container view the room embeds (inline and fullscreen
    /// share it — only one shows at a time). The active engine's
    /// video view is pinned inside it.
    let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()

    /// Re-resolve the room's streams (fresh signed URLs). Set by the
    /// room view, which owns the site + room. Called once before the
    /// next engine in the sweep, and by refresh().
    var sourceRefresh: (() async -> [PlayStream])?

    private var engines: [any PlayerEngine] = []
    private var candidates: [PlayStream] = []
    private var triedStreamIDs: Set<String> = []
    /// Whether the engine was already recreated once for a
    /// presented-frame stall in this open (wzgrx recovery step 3:
    /// recreate once, not in a loop). Reset on every open/play.
    private var engineRecreated = false
    /// The loopback relay (LoopbackRelay.swift), started lazily on
    /// the first relayed open and kept for the service's lifetime;
    /// closed in stop(). Serves the spliced FLV mpv plays from.
    private var relay: LoopbackRelay?
    /// The relay input currently owned by the playing stream, if
    /// the stream is relayed. While set, the splicer — not the
    /// lease timer — owns renewals (see engineDidBecomeReady).
    private var activeRelayInput: FlvRelayInput?
    /// The HLS relay input currently owned by the playing stream,
    /// if the line is relayed for segment restore (Bigo). While
    /// set, mpv plays from the loopback relay, not the upstream.
    private var activeHlsRelayInput: HlsRelayInput?
    private var activeEngine: (any PlayerEngine)?
    private var watchdogTask: Task<Void, Never>?
    /// Lease-refresh timer for the currently playing stream
    /// (PlayStream.expiresAt). Fires refresh() before the signed
    /// URL dies. Cancelled on every open/play/stop; (re)scheduled
    /// only when an engine actually becomes ready, so a failed
    /// candidate's lease never interrupts the stream that
    /// replaced it.
    private var leaseTask: Task<Void, Never>?
    private var lastErrorMessage: String?
    private var refreshedForEngine = false
    /// Whether the current open already re-resolved once after
    /// exhausting its candidates (wzgrx recovery step 1: at most
    /// two refreshes per budget; HAoLive allows one).
    private var generation = 0

    var isPlaying: Bool {
        state == .playing
    }

    /// Open a room's streams. Picks the best stream by preference,
    /// or reports failure when the platform offered no stream.
    func open(streams: [PlayStream], preferredQuality: String?, preferredLine: String?) {
        generation += 1
        cancelWatchdog()
        cancelLeaseRefresh()
        closeRelayInput()
        destroyEngines()
        engines = []
        availableStreams = streams
        triedStreamIDs = []
        notice = nil
        guard let best = StreamPicker.best(streams: streams, preferredQuality: preferredQuality, preferredLine: preferredLine) else {
            state = .failed("暂无可播放的线路")
            return
        }
        // mpv is the only engine (wzgrx v4; chen 19:03: no system
        // player, only mpv). If mpv cannot be created the sweep
        // finds nothing and fails honestly below.
        engines = makeEngines()
        engineRecreated = false
        refreshedForEngine = false
        lastErrorMessage = nil
        candidates = [best] + streams.filter { $0.id != best.id }
        state = .loading
        // HLS lines whose segments are masked upstream are
        // relayed so the segments are restored first (ref
        // live_media bigoRelayRecipe); FLV + lease lines go
        // through the splicer relay instead. Direct otherwise —
        // the sweep below.
        if startHlsRelayed(best) { return }
        if startRelayed(best) { return }
        tryNextCandidate()
    }

    /// Manual play: clears the failure memory first, tries this
    /// stream first, then the rest as fallback.
    func play(stream: PlayStream) {
        generation += 1
        cancelWatchdog()
        cancelLeaseRefresh()
        closeRelayInput()
        destroyEngines()
        engines = []
        triedStreamIDs = []
        notice = nil
        engines = makeEngines()
        engineRecreated = false
        refreshedForEngine = false
        lastErrorMessage = nil
        candidates = [stream] + availableStreams.filter { $0.id != stream.id }
        state = .loading
        if startHlsRelayed(stream) { return }
        if startRelayed(stream) { return }
        tryNextCandidate()
    }

    /// Switch quality / line. Pure Live: switching does not
    /// rebuild the player — the switch happens on the current
    /// engine. Same quality, different line: switch at once. A
    /// quality change re-resolves first (the signed URL for the
    /// new tier may be stale by now), then switches on the same
    /// engine. No active engine yet: fall back to play().
    func switchStream(_ stream: PlayStream) {
        guard stream != currentStream else { return }
        if stream.quality == currentStream?.quality {
            switchInEngine(stream)
            return
        }
        guard let refresh = sourceRefresh else {
            switchInEngine(stream)
            return
        }
        let generation = generation
        state = .loading
        Task {
            let fresh = await refresh()
            guard generation == self.generation else { return }
            self.availableStreams = fresh
            if let match = fresh.first(where: { $0.quality == stream.quality && $0.line == stream.line })
                ?? fresh.first(where: { $0.quality == stream.quality }) {
                self.switchInEngine(match)
            } else {
                self.play(stream: stream)
            }
        }
    }

    /// Switch to a stream on the CURRENT engine without
    /// destroying it. The old picture stays until the new stream
    /// connects (the engine's open() is a loadfile/item replace).
    /// A relayed stream is closed first; a spliceable target goes
    /// through the relay again, so every FLV + lease line plays
    /// relayed no matter how it was reached.
    private func switchInEngine(_ stream: PlayStream) {
        guard let engine = activeEngine else {
            play(stream: stream)
            return
        }
        generation += 1
        cancelWatchdog()
        cancelLeaseRefresh()
        closeRelayInput()
        triedStreamIDs = []
        notice = nil
        candidates = [stream] + availableStreams.filter { $0.id != stream.id }
        if startHlsRelayed(stream, engine: engine) { return }
        if startRelayed(stream, engine: engine) { return }
        attempt(engine: engine, stream: stream)
    }

    /// Re-resolve sources and switch on the SAME engine, keeping
    /// the current quality / line (Pure Live's lease refresh).
    /// Only when no fresh stream matches the current quality /
    /// line does it fall back to a full reopen.
    func refresh() {
        guard let refresh = sourceRefresh else { return }
        let generation = generation
        Task {
            let fresh = await refresh()
            guard generation == self.generation else { return }
            self.availableStreams = fresh
            if let current = self.currentStream,
               let match = fresh.first(where: { $0.quality == current.quality && $0.line == current.line })
                ?? fresh.first(where: { $0.quality == current.quality }) {
                self.switchInEngine(match)
            } else {
                self.open(
                    streams: fresh,
                    preferredQuality: self.currentStream?.quality,
                    preferredLine: self.currentStream?.line
                )
            }
        }
    }

    func pause() {
        activeEngine?.pause()
        if state == .playing { state = .paused }
    }

    func resume() {
        activeEngine?.play()
        if state == .paused { state = .playing }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    /// Video fit for the active engine (Pure Live's video-fit button).
    func setVideoFit(fill: Bool) {
        activeEngine?.setVideoFit(fill: fill)
    }

    func stop() {
        generation += 1
        cancelWatchdog()
        cancelLeaseRefresh()
        // Cut the upstream first, then stop the engine: the engine
        // must not read a half-closed relay as a playback failure.
        closeRelayInput()
        activeEngine?.stop()
        destroyEngines()
        relay?.close()
        relay = nil
        activeEngine = nil
        engines = []
        candidates = []
        currentStream = nil
        availableStreams = []
        triedStreamIDs = []
        lastErrorMessage = nil
        notice = nil
        engineName = "—"
        state = .idle
    }

    // MARK: - FLV relay (wzgrx flvSplice)

    /// Stops serving the active relay input, if any. The path 404s
    /// immediately and the splicer ends. Idempotent.
    private func closeRelayInput() {
        activeRelayInput?.close()
        activeRelayInput = nil
        activeHlsRelayInput?.close()
        activeHlsRelayInput = nil
    }

    /// Why a relay renewal could not resolve a fresh line. The
    /// splicer only ever logs the description (see SpliceEvent
    /// .renewFailed), so this stays a plain Sendable error.
    enum RelayRenewError: Error, Sendable {
        case noRefresher
        case noMatchingLine
    }

    /// Plays an FLV + lease line through the loopback relay when
    /// the line is spliceable (FlvRelay.shouldSplice) and a
    /// refresher exists; returns false when the line must play
    /// direct instead (not spliceable, no refresher, no engine, or
    /// the relay could not start — the caller then falls through
    /// to the direct sweep). mpv opens the relay URL once and
    /// never reopens: renewals are spliced in upstream.
    @discardableResult
    private func startRelayed(_ stream: PlayStream, engine: (any PlayerEngine)? = nil) -> Bool {
        guard FlvRelay.shouldSplice(stream: stream, canRenew: sourceRefresh != nil) else { return false }
        guard let engine = engine ?? engines.first else {
            log.error("relay: no engine to play the relayed line")
            return false
        }
        if relay == nil {
            do {
                relay = try LoopbackRelay.start()
            } catch {
                log.error("relay: loopback server failed to start: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard let relay else { return false }
        let generation = generation
        let input = relay.openFlv(
            line: stream,
            renew: { [weak self] current in
                guard let self else { throw RelayRenewError.noRefresher }
                // Hop to the main actor: sourceRefresh is a
                // non-Sendable closure the service owns, and the
                // splicer calls this from its own task.
                return try await self.renewLine(current)
            },
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleSpliceEvent(event, generation: generation) }
            },
            onRenewed: { [weak self] line in
                Task { @MainActor in self?.currentStream = line }
            }
        )
        activeRelayInput = input
        candidates = [stream]
        state = .loading
        attempt(engine: engine, stream: stream, overrideURL: input.uri)
        return true
    }

    /// Plays an HLS line whose segments are masked upstream
    /// through the loopback relay (ref live_media
    /// bigoRelayRecipe / BigoHlsProtection): the relay rewrites
    /// the playlists to point back here and un-masks each
    /// protected segment before mpv sees it. Returns false when
    /// the line needs no restore, or no engine / relay is
    /// available — the caller then falls through to the FLV
    /// relay or the direct sweep.
    @discardableResult
    private func startHlsRelayed(_ stream: PlayStream, engine: (any PlayerEngine)? = nil) -> Bool {
        guard stream.needsHlsSegmentRestore else { return false }
        guard let engine = engine ?? engines.first else {
            log.error("relay: no engine to play the relayed line")
            return false
        }
        if relay == nil {
            do {
                relay = try LoopbackRelay.start()
            } catch {
                log.error("relay: loopback server failed to start: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard let relay else { return false }
        let input = relay.openHls(line: stream) { playlist in
            guard let seed = try BigoHlsProtection.seed(fromManifest: playlist) else { return nil }
            return { segment in try BigoHlsProtection.transformSegment(segment, seed: seed) }
        }
        activeHlsRelayInput = input
        candidates = [stream]
        state = .loading
        attempt(engine: engine, stream: stream, overrideURL: input.uri)
        return true
    }

    /// Re-resolves and picks the fresh line for the same quality
    /// + line (wzgrx selectRelayRenewal: same CDN, then same
    /// quality). Runs on the main actor; the splicer's @Sendable
    /// renew closure calls it through an await hop.
    private func renewLine(_ current: PlayStream) async throws -> PlayStream {
        guard let refresh = sourceRefresh else { throw RelayRenewError.noRefresher }
        let fresh = await refresh()
        guard let match = fresh.first(where: { $0.quality == current.quality && $0.line == current.line })
            ?? fresh.first(where: { $0.quality == current.quality }) else {
            throw RelayRenewError.noMatchingLine
        }
        return match
    }

    /// Handles splicer events on the main actor. Renewals and
    /// switches need no service action — the old picture keeps
    /// playing until the new connection's first keyframe, and the
    /// splicer retries a failed renewal itself after 10 s. When
    /// the relay ends, the engine's EOF failure drives the sweep
    /// (MpvPlayerEngine reports end-file as a failure); the
    /// 3-second guard below only fires if that failure never
    /// arrives and the player is stuck on a dead stream.
    private func handleSpliceEvent(_ event: SpliceEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .renewing:
            log.info("relay: renewing")
        case let .switched(line, _, shifted, oldEnded, _):
            log.info("relay: switched to \(line.id, privacy: .public) shifted=\(shifted) oldEnded=\(oldEnded)")
        case let .renewFailed(reason):
            log.info("relay: renew failed (\(reason, privacy: .public)); old stream continues")
        case let .ended(reason):
            log.info("relay: ended (\(reason, privacy: .public))")
            let deadStream = currentStream
            activeRelayInput = nil
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard generation == self.generation,
                      self.currentStream?.id == deadStream?.id,
                      self.state == .playing else { return }
                self.lastErrorMessage = "直播流已结束"
                self.tryNextCandidate()
            }
        }
    }

    // MARK: - Sweep

    /// The engine for one open: mpv, and only mpv (wzgrx v4's
    /// "the only engine"; chen 19:03: no system player). An empty
    /// list means mpv could not be created — the sweep then fails
    /// honestly instead of playing through a wrong engine.
    private func makeEngines() -> [any PlayerEngine] {
        #if canImport(Libmpv)
        let mpv = MpvPlayerEngine()
        if mpv.isAvailable { return [mpv] }
        #endif
        return []
    }

    private func destroyEngines() {
        #if canImport(Libmpv)
        for engine in engines {
            (engine as? MpvPlayerEngine)?.destroy()
        }
        #endif
    }

    /// Next candidate on the single mpv engine. When the engine
    /// exhausts its candidates, sources are re-resolved once, then
    /// the fresh list is swept; nothing left means fail honestly.
    /// A presented-frame stall (GL black) recreates the engine
    /// once instead of sweeping on (wzgrx recovery step 3) — see
    /// engine(_:didFailWith:).
    private func tryNextCandidate() {
        cancelWatchdog()
        guard let engine = engines.first else {
            state = .failed("播放器未能初始化")
            return
        }
        if let candidate = candidates.first(where: { !triedStreamIDs.contains($0.id) && engine.canPlay($0) }) {
            // A re-resolved Bigo line must go through the HLS
            // relay again, not direct — its segments are still
            // masked upstream.
            if startHlsRelayed(candidate, engine: engine) { return }
            attempt(engine: engine, stream: candidate)
            return
        }
        if !refreshedForEngine, let refresh = sourceRefresh {
            refreshedForEngine = true
            let generation = generation
            Task {
                let fresh = await refresh()
                guard generation == self.generation else { return }
                self.availableStreams = fresh
                self.candidates = fresh
                self.tryNextCandidate()
            }
            return
        }
        state = .failed(lastErrorMessage ?? "暂无可播放的线路")
    }

    /// Tries one stream on one engine. `overrideURL` is the
    /// loopback relay URL for a spliced line: mpv opens it with
    /// no upstream headers (the relay carries them upstream
    /// itself). A direct attempt clears the relay input first —
    /// a direct stream is never relay-owned.
    private func attempt(engine: any PlayerEngine, stream: PlayStream, overrideURL: URL? = nil) {
        triedStreamIDs.insert(stream.id)
        currentStream = stream
        engineName = displayName(for: engine)
        log.info("尝试 \(self.engineName, privacy: .public) 播 \(stream.quality, privacy: .public)/\(stream.line, privacy: .public)")
        state = .loading
        activeEngine = engine
        engine.delegate = self
        attachVideoView(engine.videoView)
        if overrideURL == nil {
            activeRelayInput = nil
            // A direct attempt owns no HLS relay input either —
            // closing it drops its loopback route, so a later
            // open cannot serve a stale playlist.
            activeHlsRelayInput?.close()
            activeHlsRelayInput = nil
        }
        engine.open(url: overrideURL ?? stream.httpsURL, headers: overrideURL == nil ? stream.headers : [:], format: stream.format)
        startWatchdog(for: engine)
    }

    /// Engine display name with the mpv render path attached, so a
    /// device report can finally say GL or SW (build 11): the
    /// render path used to be invisible everywhere.
    private func displayName(for engine: any PlayerEngine) -> String {
        #if canImport(Libmpv)
        if let mpv = engine as? MpvPlayerEngine {
            let base: String
            switch mpv.renderPath {
            case .gl: base = "mpv (GL)"
            case .sw: base = "mpv (SW)"
            case .glFailed(let reason): base = "mpv (SW：GL失败：\(reason))"
            }
            // The decoder actually in use (hwdec-current): "no" =
            // software decode. Empty until the first property event
            // arrives — engineDidBecomeReady refreshes the name then.
            let decode = mpv.hwdecCurrent
            let decoded: String
            if decode.isEmpty {
                decoded = base
            } else if decode == "no" {
                decoded = "\(base) · 软解"
            } else {
                decoded = "\(base) · \(decode)"
            }
            // Build 15: Pure Live's stall diagnostics on the tag —
            // download speed (cache-speed) and dropped frames
            // (frame-drop-count, else decoder-frame-drop-count).
            // A 30M line needs 3.75 MB/s sustained; below that the
            // feed is starving. Drops climbing with a full cache
            // point at render/decode instead. The stalled case
            // stays bare so the pill reads "等缓冲" at a glance.
            if mpv.pausedForCache {
                return "等缓冲 · \(decoded)"
            }
            var tail = ""
            let seconds = Int(mpv.cacheDuration)
            if seconds > 0 { tail += " · 缓\(seconds)s" }
            let mbps = mpv.downloadBytesPerSecond / 1_000_000
            if mbps > 0 { tail += String(format: " · ↓%.1fMB/s", mbps) }
            let dropped = mpv.rendererDroppedFrames >= 0
                ? mpv.rendererDroppedFrames
                : mpv.decoderDroppedFrames
            if dropped > 0 { tail += " · 丢帧\(dropped)" }
            return decoded + tail
        }
        #endif
        return engine.name
    }

    private func attachVideoView(_ view: UIView) {
        videoContainerView.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        videoContainerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            view.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor),
        ])
    }

    // MARK: - Watchdog

    private func startWatchdog(for engine: any PlayerEngine) {
        cancelWatchdog()
        let generation = generation
        watchdogTask = Task {
            try? await Task.sleep(for: .seconds(Self.sourceReadyTimeout))
            guard generation == self.generation,
                  !Task.isCancelled,
                  self.state == .loading,
                  self.activeEngine === engine else { return }
            // Pure Live: 8 s with no picture prompts a line switch.
            // The notice names the action; the sweep does it.
            self.lastErrorMessage = "8 秒无画面，已切换线路"
            self.notice = "8 秒无画面，已切换线路"
            self.tryNextCandidate()
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Lease refresh

    /// Arm the refresh for the playing stream's lease. Pure Live's
    /// getPlayUrlRefreshAt: 45 s before expiry, or a quarter of
    /// the lifetime for short leases. A stream with no expiry
    /// gets no timer; an already-due lease refreshes at once
    /// (the fresh URL carries a fresh lease).
    private func scheduleLeaseRefresh(for stream: PlayStream) {
        cancelLeaseRefresh()
        guard let expiresAt = stream.expiresAt else { return }
        let lifetime = expiresAt.timeIntervalSinceNow
        guard lifetime > 0 else { return }
        let lead = min(45, lifetime / 4)
        let delay = lifetime - lead
        let generation = generation
        leaseTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            self.refresh()
        }
    }

    private func cancelLeaseRefresh() {
        leaseTask?.cancel()
        leaseTask = nil
    }
}

// MARK: - PlayerEngineDelegate

extension LivePlayerService: PlayerEngineDelegate {
    func engineDidBecomeReady(_ engine: any PlayerEngine) {
        guard engine === activeEngine, state == .loading else { return }
        cancelWatchdog()
        notice = nil
        state = .playing
        // Refresh the display name now: hwdec-current has arrived by
        // the first frame, so the on-screen render-path pill gains
        // the decoder (GL + 软解 is the 原画 lag signature).
        engineName = displayName(for: engine)
        log.info("就绪：\(self.engineName, privacy: .public)")
        engine.play()
        // Relayed lines are owned by the splicer: their renewal
        // instant is FlvRelay.refreshAt, not the lease timer.
        // Arming the timer here as well would double-refresh.
        if let stream = currentStream, activeRelayInput == nil {
            scheduleLeaseRefresh(for: stream)
        }
    }

    func engine(_ engine: any PlayerEngine, didFailWith message: String) {
        // Loading OR playing: a mid-stream failure (e.g. the GL
        // path going black on a resolution change) must fail over
        // too, not freeze on a dead engine. The engine identity
        // check still ignores stale failures from old engines.
        guard engine === activeEngine, state == .loading || state == .playing else { return }
        lastErrorMessage = message
        notice = message
        // wzgrx recovery step 3: a presented-frame stall (GL black)
        // recreates the engine once. The fresh engine retries GL
        // and falls to the software renderer when GL cannot be
        // built; the current stream is retried on it. Only once
        // per open — a second stall sweeps on to the next line.
        #if canImport(Libmpv)
        if let mpv = engine as? MpvPlayerEngine, mpv.glStalled, !engineRecreated,
           let stream = currentStream {
            engineRecreated = true
            log.info("GPU 渲染失败，重建播放器一次")
            destroyEngines()
            engines = makeEngines()
            activeEngine = nil
            triedStreamIDs.remove(stream.id)
            candidates = [stream] + availableStreams.filter { $0.id != stream.id }
            state = .loading
            tryNextCandidate()
            return
        }
        #endif
        tryNextCandidate()
    }

    func engineDidRenderFirstFrame(_ engine: any PlayerEngine) {
        // mpv reports ready on the first frame itself; the watchdog
        // is cancelled there. Nothing extra to do here.
    }

    func engineCacheStateDidChange(_ engine: any PlayerEngine) {
        // Live tag refresh (build 14): only the active engine's
        // buffer state shows; stale engines never rewrite the pill.
        guard engine === activeEngine else { return }
        engineName = displayName(for: engine)
    }
}
