// LoopbackRelay.swift
// HAo Live — loopback HTTP relay for FLV splicing, re-implemented from
// wzgrx/PureLive v4 (packages/live_media/lib/src/relay/loopback_relay.dart
// and upstream.dart: LoopbackRelay / openHttpFlv).
//
// Bound to 127.0.0.1 only, one random unguessable path per input that
// stops working when the input closes. mpv opens the loopback URL; the
// relay fetches the upstream over URLSession with the line's headers
// and splices lease renewals in underneath the player.
//
// The HTTP server is POSIX sockets (Darwin / Glibc), not the Network
// framework, so the Linux harness runs the real server. The upstream
// fetch is delegate-based URLSession: `URLSession.bytes` does not exist
// in swift-corelibs-foundation on Linux, and a completion-handler data
// task would buffer an endless live stream instead of streaming it.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Why the relay could not start.
enum LoopbackRelayError: Error, Sendable {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
}

@discardableResult
private func synchronized<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// File-scope wrappers so calls inside the classes below cannot resolve
/// to the classes' own `close()` methods.
private func closeSocket(_ fd: Int32) {
    _ = close(fd)
}

private func shutdownSocket(_ fd: Int32) {
    _ = shutdown(fd, Int32(SHUT_RDWR))
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let sent = bytes.withUnsafeBytes { pointer in
            send(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        }
        if sent <= 0 { return false }
        offset += sent
    }
    return true
}

private func writeAll(_ fd: Int32, _ string: String) -> Bool {
    writeAll(fd, [UInt8](string.utf8))
}

private func findHeaderEnd(_ buffer: [UInt8]) -> Int? {
    guard buffer.count >= 4 else { return nil }
    for i in 0...(buffer.count - 4) {
        if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return i
        }
    }
    return nil
}

private func readRequestHead(_ fd: Int32) -> (method: String, path: String)? {
    var buffer: [UInt8] = []
    buffer.reserveCapacity(4096)
    var chunk = [UInt8](repeating: 0, count: 1024)
    while buffer.count < 16384 {
        let count = recv(fd, &chunk, chunk.count, 0)
        if count <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<count])
        guard let end = findHeaderEnd(buffer) else { continue }
        let head = String(decoding: buffer[0..<end], as: UTF8.self)
        guard let requestLine = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (method: String(parts[0]), path: String(parts[1]))
    }
    return nil
}

// MARK: - Upstream

/// One upstream FLV connection over URLSession, framed into packets.
/// The line's URL and headers are used verbatim. Reading stops after
/// 15 s without data (wzgrx's `idleTimeout`); while the splicer is
/// behind, the task pauses above 2048 queued packets and resumes below
/// 512.
final class HttpFlvSource: NSObject, FlvPacketSource, URLSessionDataDelegate, @unchecked Sendable {
    /// Idle timeout while waiting for upstream data.
    static let idleTimeout: TimeInterval = 15
    private static let pauseAbove = 2048
    private static let resumeBelow = 512

    private let lock = NSLock()
    private let framer = FlvFramer()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var queue: [[UInt8]] = []
    private var bufferedCount = 0
    private var done = false
    private var paused = false
    private var packetContinuation: AsyncStream<[UInt8]>.Continuation!
    private var packetIterator: AsyncStream<[UInt8]>.Iterator

    /// The upstream HTTP status, once the response arrived. `nil` while
    /// the response is pending; non-200 ends the source with no packets.
    private(set) var httpStatus: Int?

    init(line: PlayStream) {
        var stream: AsyncStream<[UInt8]>!
        var continuation: AsyncStream<[UInt8]>.Continuation!
        stream = AsyncStream<[UInt8]> { continuation = $0 }
        self.packetContinuation = continuation
        self.packetIterator = stream.makeAsyncIterator()
        super.init()
        var request = URLRequest(url: line.url)
        request.httpMethod = "GET"
        for (field, value) in line.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func next() async -> [UInt8]? {
        do {
            return try await withThrowingTaskGroup(of: [UInt8]?.self) { group in
                group.addTask { await self.packetIterator.next() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
                    throw FlvSplicerError.timeout
                }
                let value = try await group.next()!
                group.cancelAll()
                if value != nil {
                    synchronized(lock) {
                        bufferedCount = max(0, bufferedCount - 1)
                        if paused && bufferedCount < Self.resumeBelow {
                            paused = false
                            task?.resume()
                        }
                    }
                }
                return value
            }
        } catch {
            // Idle timeout (or cancellation): the connection is done;
            // the splicer treats it as the upstream ending.
            cancel()
            return nil
        }
    }

    func cancel() {
        var taskToCancel: URLSessionDataTask?
        var sessionToInvalidate: URLSession?
        synchronized(lock) {
            if done {
                taskToCancel = nil
                sessionToInvalidate = nil
                return
            }
            done = true
            taskToCancel = task
            sessionToInvalidate = session
        }
        taskToCancel?.cancel()
        sessionToInvalidate?.invalidateAndCancel()
        packetContinuation.finish()
    }

    private func finish() {
        let alreadyDone = synchronized(lock) {
            let wasDone = done
            done = true
            return wasDone
        }
        if !alreadyDone {
            packetContinuation.finish()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode
        synchronized(lock) { httpStatus = status }
        if status != 200 {
            completionHandler(.cancel)
            finish()
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isDone = synchronized(lock) { done }
        guard !isDone else { return }
        let packets: [[UInt8]]
        do {
            packets = try framer.add([UInt8](data))
        } catch {
            finish()
            task?.cancel()
            return
        }
        guard !packets.isEmpty else { return }
        let shouldPause = synchronized(lock) {
            bufferedCount += packets.count
            if !paused && bufferedCount > Self.pauseAbove {
                paused = true
                return true
            }
            return false
        }
        for packet in packets {
            packetContinuation.yield(packet)
        }
        if shouldPause {
            task?.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}

// MARK: - Shared renewal

/// One renewal per lease, shared by concurrent engine connections on
/// the same input (wzgrx's `_FlvRoute._renewShared`): if another
/// splicer already renewed past this line, follow its line instead of
/// resolving again.
private final class SharedRenewer: @unchecked Sendable {
    private let renew: FlvLineRenewer
    private let lock = NSLock()
    private var current: PlayStream
    private var inflight: Task<PlayStream, Error>?

    init(line: PlayStream, renew: @escaping FlvLineRenewer) {
        self.current = line
        self.renew = renew
    }

    var line: PlayStream {
        synchronized(lock) { current }
    }

    func update(line: PlayStream) {
        synchronized(lock) { current = line }
    }

    func renew(_ line: PlayStream) async throws -> PlayStream {
        let task: Task<PlayStream, Error> = synchronized(lock) {
            if line.url != current.url {
                let followed = current
                return Task { followed }
            }
            if let inflight { return inflight }
            let fresh = Task { try await self.renew(line) }
            inflight = fresh
            return fresh
        }
        do {
            let result = try await task.value
            synchronized(lock) {
                if inflight == task { inflight = nil }
            }
            return result
        } catch {
            synchronized(lock) {
                if inflight == task { inflight = nil }
            }
            throw error
        }
    }
}

// MARK: - Relay

/// One input served on the loopback relay: an FLV splicer or an
/// HLS rewriter. The server only knows the path and the
/// connection fd; the input owns everything below its path.
protocol RelayRoute: AnyObject, Sendable {
    var isClosed: Bool { get }
    func serve(connectionFd: Int32, path: String)
    func close()
}

/// A relayed FLV input served on the loopback relay.
final class FlvRelayInput: RelayRoute, @unchecked Sendable {
    /// The loopback URL the engine opens.
    let uri: URL

    private weak var relay: LoopbackRelay?
    private let path: String
    private let timings: SpliceTimings
    private let sharedRenew: SharedRenewer
    private let onEvent: ((SpliceEvent) -> Void)?
    private let onRenewed: ((PlayStream) -> Void)?
    private let lock = NSLock()
    private var closed = false
    private var splicers: [FlvSplicer] = []

    /// The line the relay currently streams (changes on each renewal).
    var line: PlayStream { sharedRenew.line }

    /// Whether the input still serves.
    var isClosed: Bool {
        synchronized(lock) { closed } || relay?.isClosed ?? true
    }

    init(
        relay: LoopbackRelay,
        path: String,
        line: PlayStream,
        renew: @escaping FlvLineRenewer,
        onEvent: ((SpliceEvent) -> Void)?,
        onRenewed: ((PlayStream) -> Void)?,
        timings: SpliceTimings
    ) {
        self.relay = relay
        self.path = path
        self.timings = timings
        self.sharedRenew = SharedRenewer(line: line, renew: renew)
        self.onEvent = onEvent
        self.onRenewed = onRenewed
        self.uri = URL(string: "http://127.0.0.1:\(relay.port)\(path)")!
    }

    /// Stops serving; the path 404s immediately and open downstream
    /// connections end.
    func close() {
        let running: [FlvSplicer] = synchronized(lock) {
            if closed { return [] }
            closed = true
            return splicers
        }
        for splicer in running {
            splicer.cancel()
        }
        relay?.removeRoute(path: path)
    }

    /// RelayRoute dispatch: the FLV path is the input's own, so the
    /// path is ignored.
    func serve(connectionFd cfd: Int32, path: String) {
        serve(connectionFd: cfd)
    }

    /// Serves one downstream connection on `connectionFd` until the
    /// splicer ends or the client goes away. Runs on the connection
    /// thread; blocks until the stream is over.
    func serve(connectionFd cfd: Int32) {
        let state = ServeState()
        let box = SplicerBox()
        let splicer = FlvSplicer(
            line: sharedRenew.line,
            open: { line in HttpFlvSource(line: line) },
            renew: { [sharedRenew] line in try await sharedRenew.renew(line) },
            emit: { [weak box] packet in
                guard let splicer = box?.splicer else { return }
                guard state.ensureStarted(cfd: cfd) else {
                    splicer.cancel()
                    return
                }
                if !writeAll(cfd, packet) {
                    splicer.cancel()
                }
            },
            onEvent: { [weak self] event in
                if case .switched(let line, _, _, _, _) = event {
                    self?.sharedRenew.update(line: line)
                    self?.onRenewed?(line)
                }
                self?.onEvent?(event)
            },
            timings: timings
        )
        box.splicer = splicer
        synchronized(lock) { splicers.append(splicer) }
        defer {
            synchronized(lock) { splicers.removeAll { $0 === splicer } }
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await splicer.run()
                state.markFinished(error: nil)
            } catch {
                state.markFinished(error: error)
            }
            done.signal()
        }
        // Watch for the client going away while the splicer runs; the
        // splicer itself only notices a dead downstream on its next
        // send, which may never come while it waits on the upstream.
        while !state.isFinished {
            var pfd = pollfd(fd: cfd, events: Int16(POLLIN), revents: 0)
            let result = poll(&pfd, 1, 100)
            if result > 0 {
                if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                    splicer.cancel()
                    break
                }
                if (pfd.revents & Int16(POLLIN)) != 0 {
                    var scratch = [UInt8](repeating: 0, count: 512)
                    let received = recv(cfd, &scratch, scratch.count, 0)
                    if received <= 0 {
                        splicer.cancel()
                        break
                    }
                    // The client sent bytes we did not ask for (mpv
                    // never does); discard them.
                }
            } else if result < 0 {
                if errno == EINTR { continue }
                break
            }
        }
        done.wait()
        if !state.isStarted, state.runError != nil {
            _ = writeAll(
                cfd,
                "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
        }
    }
}

/// Per-connection serve state, shared between the splicer task and the
/// connection thread.
private final class ServeState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var error: (any Error)?

    /// Sends the 200 headers on the first packet. The splicer is the
    /// only caller, so the check-then-write cannot race with itself.
    func ensureStarted(cfd: Int32) -> Bool {
        if synchronized(lock, { started }) { return true }
        let ok = writeAll(
            cfd,
            "HTTP/1.1 200 OK\r\nContent-Type: video/x-flv\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        )
        if ok {
            synchronized(lock) { started = true }
        }
        return ok
    }

    var isStarted: Bool { synchronized(lock) { started } }

    func markFinished(error: (any Error)?) {
        synchronized(lock) {
            finished = true
            self.error = error
        }
    }

    var isFinished: Bool { synchronized(lock) { finished } }
    var runError: (any Error)? { synchronized(lock) { error } }
}

private final class SplicerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _splicer: FlvSplicer?
    var splicer: FlvSplicer? {
        get { synchronized(lock) { _splicer } }
        set { synchronized(lock) { _splicer = newValue } }
    }
}

// MARK: - HLS relay (wzgrx live_media HlsRoute + bigoRelayRecipe)

/// Given a media playlist's text, the segment restorer for its
/// segments, or nil when they pass through unchanged. Throwing
/// fails that playlist: a protection tag without a usable seed
/// must never serve scrambled segments to the player.
typealias HlsRestoreProvider = (String) throws -> HlsSegmentRestorer?
/// Restores one segment's bytes (Bigo's descrambling).
typealias HlsSegmentRestorer = ([UInt8]) throws -> [UInt8]

private enum HlsEntryKind: Hashable {
    case playlist
    case segment
    case map
    case key
}

private struct HlsEntry {
    var url: URL
    var kind: HlsEntryKind
    var restore: HlsSegmentRestorer?
}

/// One upstream answer fetched synchronously on a connection thread.
private final class HlsFetchBox: @unchecked Sendable {
    var result: (status: Int, data: Data)?
}

/// One HLS line served on the loopback relay (ref live_media
/// HlsRoute, simplified: no prefetch window, no lease renewal —
/// Bigo's address carries no expiry). Every playlist is fetched
/// upstream with the line's headers and rewritten so its children
/// point back here; segments of a protected media playlist go
/// through the restorer. Only addresses taken from the line's own
/// playlists are served — no open proxy.
final class HlsRelayInput: RelayRoute, @unchecked Sendable {
    /// The loopback URL the engine opens (the index playlist).
    let uri: URL
    /// The line the relay currently streams.
    let line: PlayStream

    private weak var relay: LoopbackRelay?
    private let prefix: String
    private let port: Int
    private let restoreProvider: HlsRestoreProvider
    private let lock = NSLock()
    private var closed = false
    private var entries: [String: HlsEntry] = [:]
    private var names: [String: String] = [:]
    private var mediaOrder: [String] = []
    private var next = 0

    /// Largest playlist / segment read upstream (ref HlsRoute:
    /// 4 MiB playlists, 64 MiB restored segments).
    private static let maxPlaylistBytes = 4 * 1024 * 1024
    private static let maxSegmentBytes = 64 * 1024 * 1024
    private static let maxEntries = 2048

    var isClosed: Bool {
        synchronized(lock) { closed } || relay?.isClosed ?? true
    }

    init(relay: LoopbackRelay, prefix: String, line: PlayStream, restoreProvider: @escaping HlsRestoreProvider) {
        self.relay = relay
        self.prefix = prefix
        self.port = relay.port
        self.line = line
        self.restoreProvider = restoreProvider
        self.uri = URL(string: "http://127.0.0.1:\(relay.port)\(prefix)index.m3u8")!
    }

    func close() {
        let wasClosed = synchronized(lock) {
            let was = closed
            closed = true
            return was
        }
        if !wasClosed { relay?.removeHlsRoute(prefix: prefix) }
    }

    func serve(connectionFd cfd: Int32, path: String) {
        let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        guard !name.isEmpty, !name.contains("/") else {
            _ = writeAll(cfd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let entry: HlsEntry?
        if name == "index.m3u8" {
            entry = HlsEntry(url: line.url, kind: .playlist, restore: nil)
        } else {
            entry = synchronized(lock) { entries[name] }
        }
        guard let entry else {
            _ = writeAll(cfd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        switch entry.kind {
        case .playlist:
            servePlaylist(cfd: cfd, entry: entry)
        case .segment:
            serveSegment(cfd: cfd, entry: entry)
        case .map, .key:
            serveRaw(cfd: cfd, entry: entry)
        }
    }

    private func servePlaylist(cfd: Int32, entry: HlsEntry) {
        guard let fetched = fetchUpstream(url: entry.url),
              fetched.status == 200, fetched.data.count <= Self.maxPlaylistBytes else {
            _ = writeAll(cfd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        var text = String(decoding: fetched.data, as: UTF8.self)
        // Ref HlsRoute.serve: a body that is not a playlist is a
        // bad gateway, never served to the player as one.
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            _ = writeAll(cfd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let isMaster = text.contains("#EXT-X-STREAM-INF")
        let restore: HlsSegmentRestorer?
        do {
            restore = isMaster ? nil : try restoreProvider(text)
        } catch {
            _ = writeAll(cfd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        text = rewritePlaylist(text, base: entry.url, isMaster: isMaster, restore: restore)
        let body = [UInt8](text.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard writeAll(cfd, head) else { return }
        _ = writeAll(cfd, body)
    }

    private func serveSegment(cfd: Int32, entry: HlsEntry) {
        guard let fetched = fetchUpstream(url: entry.url),
              fetched.status == 200, fetched.data.count <= Self.maxSegmentBytes else {
            _ = writeAll(cfd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        var bytes = [UInt8](fetched.data)
        if let restore = entry.restore {
            do {
                bytes = try restore(bytes)
            } catch {
                _ = writeAll(cfd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: video/MP2T\r\nCache-Control: no-store\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        guard writeAll(cfd, head) else { return }
        _ = writeAll(cfd, bytes)
    }

    private func serveRaw(cfd: Int32, entry: HlsEntry) {
        guard let fetched = fetchUpstream(url: entry.url), fetched.status == 200 else {
            _ = writeAll(cfd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let head = "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nContent-Length: \(fetched.data.count)\r\nConnection: close\r\n\r\n"
        guard writeAll(cfd, head) else { return }
        _ = writeAll(cfd, [UInt8](fetched.data))
    }

    /// Rewrites a playlist so its children point back here (ref
    /// HlsRoute.rewrite): bare lines are playlist/segment refs;
    /// URI="..." attributes of KEY/MAP/MEDIA lines are rewritten
    /// the same way. Lines that do not resolve are left as they
    /// are, exactly as the reference leaves them.
    private func rewritePlaylist(_ text: String, base: URL, isMaster: Bool, restore: HlsSegmentRestorer?) -> String {
        var out = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                out += "\n"
            } else if !line.hasPrefix("#") {
                if let url = resolveURL(line, base: base) {
                    let kind: HlsEntryKind = isMaster ? .playlist : .segment
                    out += localURLString(for: url, kind: kind, restore: kind == .segment ? restore : nil) + "\n"
                } else {
                    out += rawLine + "\n"
                }
            } else if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-MAP")
                        || line.hasPrefix("#EXT-X-MEDIA") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                out += rewriteURIAttribute(line, base: base) + "\n"
            } else {
                out += rawLine + "\n"
            }
        }
        return out
    }

    private func rewriteURIAttribute(_ line: String, base: URL) -> String {
        guard let uriRange = line.range(of: "URI=\""),
              let endQuote = line[uriRange.upperBound...].firstIndex(of: "\"") else { return line }
        let reference = String(line[uriRange.upperBound..<endQuote])
        guard let url = resolveURL(reference, base: base) else { return line }
        let kind: HlsEntryKind = line.hasPrefix("#EXT-X-MAP") ? .map : .key
        let local = localURLString(for: url, kind: kind, restore: nil)
        return line.replacingCharacters(in: uriRange.upperBound..<endQuote, with: local)
    }

    private func resolveURL(_ reference: String, base: URL) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// The local name for an upstream URL of a kind (ref
    /// HlsRoute._name): the same resource always gets the same
    /// name; segments, maps and keys are remembered oldest-first
    /// and dropped past maxEntries.
    private func localURLString(for url: URL, kind: HlsEntryKind, restore: HlsSegmentRestorer?) -> String {
        synchronized(lock) {
            let key = "\(kind) \(url.absoluteString)"
            if let known = names[key] {
                if var entry = entries[known] {
                    entry.restore = restore
                    entries[known] = entry
                }
                return "http://127.0.0.1:\(port)\(prefix)\(known)"
            }
            let number = next
            next += 1
            let name: String
            switch kind {
            case .playlist:
                name = "p\(number).m3u8"
            case .segment:
                name = "s\(number).\(url.pathExtension.isEmpty ? "ts" : url.pathExtension)"
            case .map:
                name = "m\(number).\(url.pathExtension.isEmpty ? "ts" : url.pathExtension)"
            case .key:
                name = "k\(number)"
            }
            names[key] = name
            entries[name] = HlsEntry(url: url, kind: kind, restore: restore)
            if kind != .playlist {
                mediaOrder.append(name)
                while mediaOrder.count > Self.maxEntries, let oldest = mediaOrder.first {
                    mediaOrder.removeFirst()
                    if let dropped = entries.removeValue(forKey: oldest) {
                        names.removeValue(forKey: "\(dropped.kind) \(dropped.url.absoluteString)")
                    }
                }
            }
            return "http://127.0.0.1:\(port)\(prefix)\(name)"
        }
    }

    /// One upstream GET with the line's headers, synchronously
    /// (this runs on the connection's own thread, like
    /// FlvRelayInput.serve). Nil on transport failure or timeout.
    private func fetchUpstream(url: URL) -> (status: Int, data: Data)? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        for (field, value) in line.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let box = HlsFetchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, let data {
                box.result = (http.statusCode, data)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return box.result
    }
}

/// A loopback HTTP server for relayed FLV inputs: bound to 127.0.0.1
/// only, one random unguessable path per input that stops working when
/// the input closes.
final class LoopbackRelay: @unchecked Sendable {
    /// Splice limits for every input opened on this relay.
    let timings: SpliceTimings

    private let listenFd: Int32
    private let lock = NSLock()
    /// Exact FLV paths ("/<secret>/live.flv").
    private var routes: [String: any RelayRoute] = [:]
    /// HLS prefixes ("/<secret>/"), each with one line.
    private var hlsRoutes: [String: HlsRelayInput] = [:]
    private var closed = false

    /// Loopback port.
    private(set) var port: Int

    /// Whether `close()` ran.
    var isClosed: Bool { synchronized(lock) { closed } }

    private init(listenFd: Int32, port: Int, timings: SpliceTimings) {
        self.listenFd = listenFd
        self.port = port
        self.timings = timings
    }

    /// Starts a relay on an ephemeral loopback port.
    static func start(timings: SpliceTimings = SpliceTimings()) throws -> LoopbackRelay {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #elseif canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw LoopbackRelayError.socket(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            closeSocket(fd)
            throw LoopbackRelayError.bind(errno)
        }
        guard listen(fd, 16) == 0 else {
            closeSocket(fd)
            throw LoopbackRelayError.listen(errno)
        }
        var name = sockaddr_in()
        var nameLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &nameLength)
            }
        }
        let port = Int(UInt16(bigEndian: name.sin_port))
        let relay = LoopbackRelay(listenFd: fd, port: port, timings: timings)
        Thread.detachNewThread { [weak relay] in relay?.acceptLoop() }
        return relay
    }

    /// Serves the FLV `line` as one continuous stream. With `renew`,
    /// a lease that cuts the connection is renewed and spliced in
    /// (see `FlvSplicer`); without a working renewer the stream ends
    /// with its upstream. `onRenewed` fires with each line switched to.
    func openFlv(
        line: PlayStream,
        renew: @escaping FlvLineRenewer,
        onEvent: ((SpliceEvent) -> Void)? = nil,
        onRenewed: ((PlayStream) -> Void)? = nil
    ) -> FlvRelayInput {
        precondition(!isClosed, "LoopbackRelay is closed")
        let secret = Self.randomSecret()
        let path = "/\(secret)/live.flv"
        let input = FlvRelayInput(
            relay: self,
            path: path,
            line: line,
            renew: renew,
            onEvent: onEvent,
            onRenewed: onRenewed,
            timings: timings
        )
        synchronized(lock) { routes[path] = input }
        return input
    }

    func removeRoute(path: String) {
        synchronized(lock) { routes.removeValue(forKey: path) }
    }

    /// Serves the HLS `line` (ref live_media HlsRoute + Bigo's
    /// bigoRelayRecipe): playlists are rewritten to point back
    /// here, and segments of a protected media playlist go through
    /// the restorer from `restoreProvider`.
    func openHls(
        line: PlayStream,
        restoreProvider: @escaping HlsRestoreProvider
    ) -> HlsRelayInput {
        precondition(!isClosed, "LoopbackRelay is closed")
        let prefix = "/\(Self.randomSecret())/"
        let input = HlsRelayInput(relay: self, prefix: prefix, line: line, restoreProvider: restoreProvider)
        synchronized(lock) { hlsRoutes[prefix] = input }
        return input
    }

    func removeHlsRoute(prefix: String) {
        synchronized(lock) { hlsRoutes.removeValue(forKey: prefix) }
    }

    /// Stops the server and every input.
    func close() {
        let inputs: [any RelayRoute] = synchronized(lock) {
            if closed { return [] }
            closed = true
            let current: [any RelayRoute] = Array(routes.values) + Array(hlsRoutes.values)
            routes.removeAll()
            hlsRoutes.removeAll()
            return current
        }
        for input in inputs {
            input.close()
        }
        shutdownSocket(listenFd)
        closeSocket(listenFd)
    }

    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func acceptLoop() {
        while !isClosed {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let connectionFd = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFd, $0, &length)
                }
            }
            if connectionFd < 0 {
                if isClosed { break }
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.handleConnection(connectionFd)
            }
        }
    }

    private func handleConnection(_ connectionFd: Int32) {
        defer { closeSocket(connectionFd) }
        guard let request = readRequestHead(connectionFd),
              request.method == "GET" else {
            _ = writeAll(connectionFd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        if let input = synchronized(lock, { routes[path] }), !input.isClosed, !isClosed {
            input.serve(connectionFd: connectionFd, path: path)
            return
        }
        if let input = synchronized(lock, { hlsRoutes.first { path.hasPrefix($0.key) }?.value }),
           !input.isClosed, !isClosed {
            input.serve(connectionFd: connectionFd, path: path)
            return
        }
        _ = writeAll(connectionFd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
}
