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

/// A relayed FLV input served on the loopback relay.
final class FlvRelayInput: @unchecked Sendable {
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

/// A loopback HTTP server for relayed FLV inputs: bound to 127.0.0.1
/// only, one random unguessable path per input that stops working when
/// the input closes.
final class LoopbackRelay: @unchecked Sendable {
    /// Splice limits for every input opened on this relay.
    let timings: SpliceTimings

    private let listenFd: Int32
    private let lock = NSLock()
    private var routes: [String: FlvRelayInput] = [:]
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

    /// Stops the server and every input.
    func close() {
        let inputs: [FlvRelayInput] = synchronized(lock) {
            if closed { return [] }
            closed = true
            let current = Array(routes.values)
            routes.removeAll()
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
        let input = synchronized(lock) { routes[path] }
        guard let input, !input.isClosed, !isClosed else {
            _ = writeAll(connectionFd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        input.serve(connectionFd: connectionFd)
    }
}
