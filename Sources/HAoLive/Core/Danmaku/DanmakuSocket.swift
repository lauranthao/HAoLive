// DanmakuSocket.swift
// HAo Live — one socket abstraction for every danmaku channel.
// Bilibili/Douyin/Kuaishou/Huya speak WebSocket; Douyu speaks raw TCP.
// The decoders only ever see Data, so the Linux harness can drive them
// with a scripted socket instead of a real connection.

import Foundation

/// Minimal byte-stream socket: connect, send one frame, receive one
/// frame, close. Transports own their threading; callers use it from
/// a single pump task.
protocol DanmakuSocket: AnyObject, Sendable {
    func connect(url: URL, headers: [String: String]) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

#if !os(Linux)
/// WebSocket transport backed by URLSessionWebSocketTask.
/// `url` may be ws:// or wss://; headers are set on the handshake.
final class WebSocketTransport: DanmakuSocket, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?

    func connect(url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.setValue(HTTPClient.shared.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw LiveSiteError.networkUnavailable }
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        guard let task else { throw LiveSiteError.networkUnavailable }
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return Data()
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
#endif

#if canImport(Network)
import Network

/// One-shot resume flag for a continuation. The stateUpdateHandler runs on the
/// connection's serial queue, so the flag is only ever touched from one queue;
/// the box exists so Swift 6's concurrency checker accepts the capture
/// (a captured `var` mutated in concurrently-executing code is an error).
final class ResumedFlag: @unchecked Sendable {
    var value = false
}

/// Raw TCP transport backed by NWConnection (Douyu's danmaku server).
/// `url` is a tcp://host:port URL; headers are ignored.
final class TCPTransport: DanmakuSocket, @unchecked Sendable {
    private let queue = DispatchQueue(label: "hao.live.tcp")
    private var connection: NWConnection?
    private var pending: CheckedContinuation<Data, Error>?
    private var buffered = Data()
    private var closed = false

    func connect(url: URL, headers: [String: String]) async throws {
        guard let host = url.host, let port = url.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw LiveSiteError.invalidResponse
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed.value { resumed.value = true; continuation.resume() }
                case .failed(let error):
                    if !resumed.value { resumed.value = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed.value { resumed.value = true; continuation.resume(throwing: LiveSiteError.networkUnavailable) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        pumpReceive()
    }

    func send(_ data: Data) async throws {
        guard let connection else { throw LiveSiteError.networkUnavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LiveSiteError.networkUnavailable)
                    return
                }
                if !self.buffered.isEmpty {
                    let data = self.buffered
                    self.buffered = Data()
                    continuation.resume(returning: data)
                } else if self.closed {
                    continuation.resume(throwing: LiveSiteError.networkUnavailable)
                } else {
                    self.pending = continuation
                }
            }
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.connection?.cancel()
            self.connection = nil
            if let pending = self.pending {
                self.pending = nil
                pending.resume(throwing: LiveSiteError.networkUnavailable)
            }
        }
    }

    private func pumpReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffered.append(data)
                if let pending = self.pending {
                    self.pending = nil
                    let out = self.buffered
                    self.buffered = Data()
                    pending.resume(returning: out)
                }
            }
            if error != nil || isComplete {
                self.failPending()
                return
            }
            if !self.closed {
                self.pumpReceive()
            }
        }
    }

    private func failPending() {
        if let pending = self.pending {
            self.pending = nil
            pending.resume(throwing: LiveSiteError.networkUnavailable)
        }
    }
}
#endif
