// KilakilaDanmaku.swift
// HAo Live — Kilakila danmaku over the socket.io (EIO=3) channel
// (wss://wim.hongrenshuo.com.cn/socket.io/). Re-implemented from
// Pure Live's KilakilaDanmaku, with one correction: socket.io EVENT
// packets are type "2" ("42" frames), so chat arrives as
//   42/live_chat_room_guest,["text_message","{...}"]
// and is parsed on that shape; Pure Live's packet-"4" branch does
// not match EVENT frames. The room id here is the anchor UID — the
// broadcast roomId is resolved first via the owner endpoint
// (KilakilaSite.owner), exactly as roomDetail does.
//
// Flow: connect, send the namespace connect
//   40/live_chat_room_guest?roomId={roomId}&appId=111&clientType=1,
// ping "2" every 25s, chat events carry
//   envelope.body.response.content {t, c (text), n (nick),
//   u (uid), l (level)}; t == 200 is chat, t == 637 is an
//   audience update (ignored — the overlay is chat only).
// Join timeout 8s, then the attempt ends and the loop retries
// with backoff. NOT yet verified against the live server from
// this VM — needs a domestic real-device check.

import Foundation

enum KilakilaDanmaku {
    static let host = "wim.hongrenshuo.com.cn"
    static let namespace = "/live_chat_room_guest"
    static let pingIntervalSeconds: UInt64 = 25
    static let joinTimeoutSeconds: UInt64 = 8
    static let chatType = 200

    static func query(roomID: String) -> String {
        "roomId=\(roomID)&appId=111&clientType=1"
    }

    static func socketURL(roomID: String) -> URL? {
        URL(string: "wss://\(host)/socket.io/?\(query(roomID: roomID))&EIO=3&transport=websocket")
    }

    /// The namespace connect packet.
    static func connectPacket(roomID: String) -> String {
        "40\(namespace)?\(query(roomID: roomID)),"
    }

    /// Resolve the anchor UID to its current broadcast roomId via
    /// the owner endpoint. Nil when the anchor is not live.
    static func broadcastRoomID(uid: String) async -> String? {
        guard let owner = try? await KilakilaSite.owner(uid: uid) else { return nil }
        guard owner.currentStatus == 4 else { return nil }
        return owner.currentRoomID
    }

    /// Parse one socket.io EVENT frame into a chat item (or nil).
    /// Testable without the network.
    static func chatItem(fromFrame text: String, roomID: String) -> DanmakuItem? {
        guard text.hasPrefix("42") else { return nil }
        let rest = String(text.dropFirst(2))
        guard rest.hasPrefix(namespace) else { return nil }
        let afterNamespace = String(rest.dropFirst(namespace.count))
        guard afterNamespace.hasPrefix(",") else { return nil }
        let body = String(afterNamespace.dropFirst())
        guard let data = body.data(using: .utf8),
              let decoded = JSONValue.parse(data),
              decoded.arrayValue.count >= 2,
              decoded[0].stringValue == "text_message",
              let payloadString = decoded[1].stringValue,
              let payloadData = payloadString.data(using: .utf8),
              let envelope = JSONValue.parse(payloadData) else { return nil }
        let content = envelope["body"]["response"]["content"]
        guard content["t"].intValue == chatType,
              let raw = content["c"].stringValue, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DanmakuItem(
            roomID: roomID,
            user: content["n"].stringValue ?? "",
            text: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// True when the frame is the namespace connect success
    /// ("40" + namespace, optionally followed by a JSON payload).
    static func isNamespaceConnected(_ text: String) -> Bool {
        text == "40\(namespace)" || text.hasPrefix("40\(namespace),")
    }

    /// True when the frame is a ["connect_error", ...] EVENT with
    /// code 0 — the server's other way of saying "joined".
    static func isConnectErrorZero(_ text: String) -> Bool {
        guard text.hasPrefix("42") else { return false }
        let rest = String(text.dropFirst(2))
        guard rest.hasPrefix(namespace),
              let comma = rest.firstIndex(of: ",") else { return false }
        let body = String(rest[rest.index(after: comma)...])
        guard let data = body.data(using: .utf8),
              let decoded = JSONValue.parse(data),
              decoded[0].stringValue == "connect_error" else { return false }
        return decoded[1]["code"].intValue == 0
    }

#if !os(Linux)
    /// Live stream of danmaku for an anchor UID. Resolves the
    /// broadcast room, joins the socket.io namespace, and yields
    /// chat items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let broadcastID = await broadcastRoomID(uid: roomID),
                      let url = socketURL(roomID: broadcastID) else {
                    continuation.finish()
                    return
                }
                var attempt = 0
                while !Task.isCancelled {
                    await runSocket(url: url, broadcastID: broadcastID, roomID: roomID, continuation: continuation)
                    if Task.isCancelled { break }
                    // The socket ended without joining or dropped;
                    // back off and retry.
                    attempt += 1
                    let delay = min(attempt, 8)
                    try? await Task.sleep(for: .seconds(delay))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One socket attempt: joins the namespace and yields chat
    /// until the socket ends, the join times out, or the task is
    /// cancelled.
    private static func runSocket(url: URL, broadcastID: String, roomID: String, continuation: AsyncStream<DanmakuItem>.Continuation) async {
        let socket: any DanmakuSocket = WebSocketTransport()
        do {
            try await socket.connect(url: url, headers: ["Origin": "https://www.hongrenshuo.com.cn"])
            try await socket.send(Data(connectPacket(roomID: broadcastID).utf8))
            let ping = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Int(pingIntervalSeconds)))
                    try? await socket.send(Data("2".utf8))
                }
            }
            defer { ping.cancel() }
            // Join watchdog: receive() has no timeout of its own, so
            // a silent socket is closed 8s after connect when the
            // namespace never confirmed the join.
            let joinBox = JoinBox()
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Int(joinTimeoutSeconds)))
                if !joinBox.joined { socket.close() }
            }
            defer { watchdog.cancel() }
            while !Task.isCancelled {
                let data = try await socket.receive()
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let frame = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if frame.isEmpty { continue }
                if frame == "2" {
                    // Server ping: answer with a pong.
                    try? await socket.send(Data("3".utf8))
                    continue
                }
                if frame.hasPrefix("3") || frame.hasPrefix("1") { continue }
                if frame.hasPrefix("0") {
                    // Open packet arrived after our connect; make
                    // sure the namespace join went out.
                    try? await socket.send(Data(connectPacket(roomID: broadcastID).utf8))
                    continue
                }
                if isNamespaceConnected(frame) || isConnectErrorZero(frame) {
                    joinBox.joined = true
                    continue
                }
                if frame.hasPrefix("41") { break }
                if let item = chatItem(fromFrame: frame, roomID: roomID) {
                    joinBox.joined = true
                    continuation.yield(item)
                    continue
                }
            }
            socket.close()
        } catch {
            socket.close()
        }
    }

    /// Join flag shared with the watchdog task.
    private final class JoinBox: @unchecked Sendable {
        var joined = false
    }
#endif
}
