// KickDanmaku.swift
// HAo Live — Kick danmaku over Kick's public Pusher channel
// (read-only: the app never sends chat messages).
//
// Flow, verified live from this VM 2026-11-28 against a real room
// (cuvey, ~1000 viewers):
//   1. GET kick.com/api/v2/channels/{slug} -> channel id and the
//      distinct chatroom id (e.g. channel 99876, chatroom 99874).
//   2. POST web.kick.com/api/v1/realtime/channels/{channelId}/
//      chat/connection, body
//        {"client": {"id": "<uuid>", "type": "web"},
//         "capabilities": {"accepted_providers":
//           [{"provider": "pusher"}]}}
//      -> {data: {connections: [{credentials: {app_key, cluster},
//         provider: "pusher"}], mode: "websocket"}}
//      The credentials are issued at runtime by Kick's own
//      anonymous endpoint (the web client does the same); no key
//      is copied into the code.
//   3. wss://ws-{cluster}.pusher.com/app/{app_key}?protocol=7
//      &client=js&version=8.4.0&flash=false; subscribe to
//      "chatrooms.{chatroomId}.v2" (public channel, empty auth);
//      chat arrives as "App\Events\ChatMessageEvent" with
//      data {id, content, sender: {username, slug,
//      identity: {color, ...}}}. Pusher ping is answered with pong.
//   Verified end to end: connection_established, subscription
//   succeeded, 3 real chat messages in ~10s.

import Foundation

enum KickDanmaku {
    static let laravelBase = "https://kick.com"
    static let webBase = "https://web.kick.com"
    static let pusherClientVersion = "8.4.0"

    /// The ids the realtime handshake needs: the channel id (for
    /// the connection endpoint) and the distinct chatroom id (for
    /// the Pusher subscription).
    struct ChannelInfo {
        let channelID: Int
        let chatroomID: Int
    }

    /// Pusher credentials issued at runtime by Kick's anonymous
    /// realtime endpoint.
    struct Credentials {
        let appKey: String
        let cluster: String
    }

    /// GET kick.com/api/v2/channels/{slug} -> channel + chatroom ids.
    static func channelInfo(slug: String) async -> ChannelInfo? {
        guard let json = try? await HTTPClient.shared.getJSON("\(laravelBase)/api/v2/channels/\(slug)"),
              let channelID = json["id"].intValue,
              let chatroomID = json["chatroom"]["id"].intValue else { return nil }
        return ChannelInfo(channelID: channelID, chatroomID: chatroomID)
    }

    /// POST the realtime connection endpoint offering only the
    /// pusher provider; the server answers with the public
    /// app_key / cluster for this session.
    static func pusherCredentials(channelID: Int, clientID: String) async -> Credentials? {
        let body: [String: Any] = [
            "client": ["id": clientID, "type": "web"],
            "capabilities": ["accepted_providers": [["provider": "pusher"]]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []),
              let json = try? await HTTPClient.shared.postJSONParsed(
                  "\(webBase)/api/v1/realtime/channels/\(channelID)/chat/connection",
                  jsonData: bodyData,
                  headers: ["Referer": "https://kick.com", "x-app-platform": "web"]
              ) else { return nil }
        let credentials = json["data"]["connections"][0]["credentials"]
        guard let appKey = credentials["app_key"].stringValue, !appKey.isEmpty,
              let cluster = credentials["cluster"].stringValue, !cluster.isEmpty else { return nil }
        return Credentials(appKey: appKey, cluster: cluster)
    }

    /// Pusher WebSocket URL for these credentials.
    static func webSocketURL(credentials: Credentials) -> URL? {
        URL(string: "wss://ws-\(credentials.cluster).pusher.com/app/\(credentials.appKey)?protocol=7&client=js&version=\(pusherClientVersion)&flash=false")
    }

    /// Decode one Pusher frame (already parsed JSON) into danmaku
    /// items (usually 0 or 1). The chat event's `data` arrives as a
    /// JSON-encoded string, like every Pusher payload. Testable
    /// without the network.
    static func decodeMessage(_ frame: JSONValue, roomID: String) -> [DanmakuItem] {
        guard let event = frame["event"].stringValue,
              event.hasSuffix("ChatMessageEvent"),
              let dataText = frame["data"].stringValue,
              let data = JSONValue.parse(Data(dataText.utf8)),
              let item = parseChatMessage(data, roomID: roomID) else { return [] }
        return [item]
    }

    /// Parse one ChatMessageEvent payload: user =
    /// sender.username, text = content, colour =
    /// sender.identity.color when it is a #hex string.
    static func parseChatMessage(_ data: JSONValue, roomID: String) -> DanmakuItem? {
        guard let text = data["content"].stringValue, !text.isEmpty else { return nil }
        let sender = data["sender"]
        let user = HaoText.firstNonEmpty(sender["username"].stringValue, sender["slug"].stringValue) ?? ""
        var colorHex = ""
        if let color = sender["identity"]["color"].stringValue, color.hasPrefix("#") {
            colorHex = color
        }
        return DanmakuItem(
            id: data["id"].stringValue ?? UUID().uuidString,
            roomID: roomID,
            user: user,
            text: text,
            colorHex: colorHex
        )
    }

    /// Pusher subscribe frame for a chatroom (public channel: the
    /// auth field is empty, as the web client sends it).
    static func subscribeData(chatroomID: Int) -> Data? {
        let body: [String: Any] = [
            "event": "pusher:subscribe",
            "data": ["auth": "", "channel": "chatrooms.\(chatroomID).v2"],
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// Pusher pong frame.
    static func pongData() -> Data? {
        let body: [String: Any] = ["event": "pusher:pong", "data": [:] as [String: Any]]
        return try? JSONSerialization.data(withJSONObject: body, options: [])
    }

#if !os(Linux)
    /// Live stream of danmaku for a room (roomID is the channel
    /// slug). Resolves the channel/chatroom ids, fetches Pusher
    /// credentials, subscribes, answers ping with pong, and yields
    /// items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let info = await channelInfo(slug: roomID) else {
                    continuation.finish()
                    return
                }
                guard let credentials = await pusherCredentials(channelID: info.channelID, clientID: UUID().uuidString),
                      let url = webSocketURL(credentials: credentials),
                      let subscribe = subscribeData(chatroomID: info.chatroomID) else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: [:])
                    try await socket.send(subscribe)
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        guard let text = String(data: data, encoding: .utf8),
                              let frame = JSONValue.parse(Data(text.utf8)) else { continue }
                        if frame["event"].stringValue == "pusher:ping",
                           let pong = pongData() {
                            try? await socket.send(pong)
                            continue
                        }
                        for item in decodeMessage(frame, roomID: roomID) {
                            continuation.yield(item)
                        }
                    }
                } catch {
                    // Connection dropped: the stream simply ends.
                }
                socket.close()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
