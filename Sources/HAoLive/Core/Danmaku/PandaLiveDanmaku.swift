// PandaLiveDanmaku.swift
// HAo Live — PandaLive danmaku over the chat WebSocket
// (wss://chat-ws.neolive.kr/connection/websocket).
// Re-implemented from Pure Live's PandaLiveDanmaku.
//
// Flow: the channel + token come from the live/play call
// (PandaLiveSite.chatArgs, re-fetched fresh — tokens expire).
// On open, send:
//   {"params":{"token":token,"name":"js"},"id":1}
//   {"method":1,"params":{"channel":channel},"id":2}
// then ping {"method":7,"id":n} every 25s. Frames are
// newline-separated JSON objects. The id==1 reply carries a ttl;
// the socket is refreshed (new token) ttl-60s later. Chat frames
// carry result.channel + result.data.data:
//   {type: bj/chatter/manager/support, message, nick/userNick,
//   userId, created_at} with result.data.offset as the sequence.
// NOT yet verified against the live server from this VM —
// needs a domestic real-device check.

import Foundation

enum PandaLiveDanmaku {
    static let server = "wss://chat-ws.neolive.kr/connection/websocket"
    static let pingIntervalSeconds: UInt64 = 25

    /// Parse one newline-separated frame line into a chat item
    /// (or nil). Testable without the network.
    static func chatItem(fromLine line: String, roomID: String) -> DanmakuItem? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let decoded = JSONValue.parse(data),
              !decoded.isNull else { return nil }
        let result = decoded["result"]
        guard !result.isNull else { return nil }
        // Replies to our own commands (id 1 / 2 / ping) carry no
        // channel payload.
        if !decoded["id"].isNull { return nil }
        let channel = result["channel"].stringValue ?? ""
        guard !channel.isEmpty else { return nil }
        let payload = result["data"]
        guard !payload.isNull else { return nil }
        let message = payload["data"]
        guard !message.isNull else { return nil }
        return chatItem(fromMessage: message, channel: channel,
                        offset: payload["offset"].stringValue ?? "", roomID: roomID)
    }

    /// Parse one chat message object. Only bj / chatter /
    /// manager / support messages are chat. Testable without the
    /// network.
    static func chatItem(fromMessage message: JSONValue, channel: String, offset: String, roomID: String) -> DanmakuItem? {
        let type = message["type"].stringValue ?? ""
        guard type == "bj" || type == "chatter" || type == "manager" || type == "support" else { return nil }
        let text = message["message"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        let nick = HaoText.firstNonEmpty(
            message["nick"].stringValue,
            message["userNick"].stringValue,
            message["userId"].stringValue) ?? ""
        return DanmakuItem(
            id: offset.isEmpty ? UUID().uuidString : "\(channel):\(offset)",
            roomID: roomID,
            user: nick,
            text: text
        )
    }

    /// The ttl (seconds) of the id==1 token reply, or nil.
    /// Testable without the network.
    static func tokenTTL(fromLine line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let decoded = JSONValue.parse(data),
              decoded["id"].intValue == 1,
              let ttl = decoded["result"]["ttl"].intValue, ttl > 0 else { return nil }
        return ttl
    }

#if !os(Linux)
    /// Live stream of danmaku for a BJ user id. Fetches fresh
    /// chat args, connects, and yields chat items until cancelled.
    /// Reconnects with backoff; refreshes the token when its ttl
    /// runs down (ttl - 60s) or after a drop.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let initial = await PandaLiveSite.chatArgs(userID: roomID) else {
                    continuation.finish()
                    return
                }
                var args = initial
                var attempt = 0
                while !Task.isCancelled {
                    await runSocket(channel: args.channel, token: args.token, roomID: roomID, continuation: continuation)
                    if Task.isCancelled { break }
                    attempt += 1
                    try? await Task.sleep(for: .seconds(min(attempt, 8)))
                    if let refreshed = await PandaLiveSite.chatArgs(userID: roomID) {
                        args = refreshed
                    } else if attempt > 3 {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One chat socket attempt.
    private static func runSocket(channel: String, token: String, roomID: String, continuation: AsyncStream<DanmakuItem>.Continuation) async {
        guard let url = URL(string: server) else { return }
        let socket: any DanmakuSocket = WebSocketTransport()
        do {
            try await socket.connect(url: url, headers: [:])
            // Connect commands: token first, then the channel.
            try await socket.send(Data(connectCommands(token: token, channel: channel)[0].utf8))
            try await socket.send(Data(connectCommands(token: token, channel: channel)[1].utf8))
            var nextID = 2
            let ping = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Int(pingIntervalSeconds)))
                    nextID += 1
                    try? await socket.send(Data("{\"method\":7,\"id\":\(nextID)}".utf8))
                }
            }
            defer { ping.cancel() }
            // Token refresh: the id==1 reply carries a ttl; when it
            // runs down (ttl - 60s) the socket is closed so the
            // outer loop reconnects with a fresh token.
            var refreshTask: Task<Void, Never>?
            defer { refreshTask?.cancel() }
            while !Task.isCancelled {
                let data = try await socket.receive()
                guard let text = String(data: data, encoding: .utf8) else { continue }
                for line in text.components(separatedBy: .newlines) {
                    if let ttl = tokenTTL(fromLine: line), ttl > 60 {
                        refreshTask?.cancel()
                        refreshTask = Task {
                            try? await Task.sleep(for: .seconds(ttl - 60))
                            if !Task.isCancelled { socket.close() }
                        }
                    }
                    if let item = chatItem(fromLine: line, roomID: roomID) {
                        continuation.yield(item)
                    }
                }
            }
            socket.close()
        } catch {
            socket.close()
        }
    }

    private static func connectCommands(token: String, channel: String) -> [String] {
        [
            "{\"params\":{\"token\":\"\(token)\",\"name\":\"js\"},\"id\":1}",
            "{\"method\":1,\"params\":{\"channel\":\"\(channel)\"},\"id\":2}",
        ]
    }
#endif
}
