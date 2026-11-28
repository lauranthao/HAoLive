// ChzzkDanmaku.swift
// HAo Live — CHZZK danmaku over Naver's chat WebSocket.
// Protocol from the Pure Live reference (chzzk_danmaku.dart),
// re-implemented from scratch; no keys or secrets involved.
//
// Flow: GET /service/v3.1/channels/{channelId}/live-detail ->
// chatChannelId; GET comm-api.game.naver.com/nng_main/v1/chats/
// access-token?channelId=&chatType=STREAMING -> content.accessToken;
// GET routing.chat.naver.com/routing/getRouting?serviceId=game ->
// result.sessionServerList[] (hosts ending .chat.naver.com).
// Connect wss://{server}/chat, send the join frame
// {ver:"3",cmd:100,svcid:"game",cid,bdy:{uid:null,devType:2001,
// accTkn:token,auth:"READ"},tid:1}; ping {ver:"3",cmd:0,tid:n}
// every 20s. Chat arrives as cmd 93101/93102, bdy.msgTypeCode
// 1/10/11, msgStatusType NORMAL, msg/content text, profile.nickname
// (profile may itself be a JSON string). cmd 90102 ends the session;
// cmd 302–304 means the join was rejected.
// NOTE: frames are sent as binary WebSocket messages carrying UTF-8
// JSON (WebSocketTransport only sends .data) — verified against the
// live server only up to the token/routing calls from this VM; the
// socket join itself needs a domestic real-device check.

import Foundation

enum ChzzkDanmaku {
    static let heartbeatIntervalSeconds: UInt64 = 20
    private static let apiBase = "https://api.chzzk.naver.com"
    private static let webOrigin = "https://chzzk.naver.com"

    /// chatChannelId for a channel, from the v3.1 live-detail.
    static func chatChannelID(for channelID: String) async -> String? {
        guard let json = try? await HTTPClient.shared.getJSON(
            "\(apiBase)/service/v3.1/channels/\(channelID)/live-detail",
            headers: ["Origin": webOrigin, "Referer": "\(webOrigin)/"]
        ), json["code"].intValue == 200 else { return nil }
        let id = json["content"]["chatChannelId"].stringValue ?? ""
        return id.isEmpty ? nil : id
    }

    /// Chat access token (anonymous, no login).
    static func accessToken(chatChannelID: String) async -> String? {
        let url = ChzzkSite.urlWithQuery(
            "https://comm-api.game.naver.com/nng_main/v1/chats/access-token",
            [("channelId", chatChannelID), ("chatType", "STREAMING")]
        )
        guard let json = try? await HTTPClient.shared.getJSON(url, headers: ["Origin": webOrigin]) else { return nil }
        let token = json["content"]["accessToken"].stringValue ?? ""
        return token.isEmpty ? nil : token
    }

    /// Chat session servers, in routing order.
    static func sessionServers() async -> [String] {
        let url = ChzzkSite.urlWithQuery(
            "https://routing.chat.naver.com/routing/getRouting",
            [("serviceId", "game")]
        )
        guard let json = try? await HTTPClient.shared.getJSON(url, headers: ["Origin": webOrigin]) else { return [] }
        var servers: [String] = []
        for entry in json["result"]["sessionServerList"].arrayValue {
            let host = (entry.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty, host.hasSuffix(".chat.naver.com"), !servers.contains(host) else { continue }
            let firstLabel = host.split(separator: ".").first.map(String.init) ?? ""
            guard firstLabel.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { continue }
            servers.append(host)
            guard servers.count < 16 else { break }
        }
        return servers
    }

    /// Join frame (cmd 100). `tid` is the caller's running counter.
    static func joinFrame(chatChannelID: String, token: String, tid: Int) -> Data {
        let body: [String: Any] = [
            "uid": NSNull(), "devType": 2001, "accTkn": token, "auth": "READ",
        ]
        let frame: [String: Any] = [
            "ver": "3", "cmd": 100, "svcid": "game", "cid": chatChannelID,
            "bdy": body, "tid": tid,
        ]
        return (try? JSONSerialization.data(withJSONObject: frame, options: [])) ?? Data()
    }

    /// Ping frame (cmd 0).
    static func pingFrame(tid: Int) -> Data {
        let frame: [String: Any] = ["ver": "3", "cmd": 0, "tid": tid]
        return (try? JSONSerialization.data(withJSONObject: frame, options: [])) ?? Data()
    }

    /// Decode one WebSocket frame. Returns (items, shouldClose).
    /// Testable without the network.
    static func decodeFrame(_ data: Data, roomID: String) -> (items: [DanmakuItem], shouldClose: Bool) {
        guard let text = String(data: data, encoding: .utf8),
              let raw = text.data(using: .utf8),
              let json = JSONValue.parse(raw),
              !json.isNull else { return ([], false) }
        let cmd = json["cmd"].intValue ?? 0
        if cmd == 90102 { return ([], true) }
        if cmd == 93101 || cmd == 93102 {
            if let item = chatItem(fromBody: json["bdy"], roomID: roomID) {
                return ([item], false)
            }
        }
        return ([], false)
    }

    /// One chat message body -> DanmakuItem. Nil for non-chat types
    /// (msgTypeCode 1/10/11 only) or non-NORMAL / empty messages.
    static func chatItem(fromBody body: JSONValue, roomID: String) -> DanmakuItem? {
        guard !body.isNull else { return nil }
        let type = Int(body["msgTypeCode"].stringValue ?? body["messageTypeCode"].stringValue ?? "") ?? 1
        guard type == 1 || type == 10 || type == 11 else { return nil }
        let status = body["msgStatusType"].stringValue ?? body["messageStatusType"].stringValue ?? ""
        guard status.isEmpty || status == "NORMAL" else { return nil }
        let rawText = body["msg"].stringValue ?? body["content"].stringValue ?? ""
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var profile = body["profile"]
        if let encoded = profile.stringValue, encoded.hasPrefix("{"),
           let data = encoded.data(using: .utf8), let parsed = JSONValue.parse(data) {
            profile = parsed
        }
        let user = profile["nickname"].stringValue ?? ""
        let millis = Int(body["msgTime"].stringValue ?? body["messageTime"].stringValue ?? "") ?? 0
        return DanmakuItem(
            roomID: roomID,
            user: user,
            text: text,
            colorHex: "",
            timestamp: millis > 0 ? Date(timeIntervalSince1970: TimeInterval(millis) / 1000) : Date()
        )
    }

#if !os(Linux)
    /// Live stream of danmaku for a channel. Resolves the chat
    /// channel + token + routing, joins the chat socket, pings
    /// every 20s, and yields items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let chatChannelID = await chatChannelID(for: roomID),
                      let token = await accessToken(chatChannelID: chatChannelID),
                      let server = await sessionServers().first,
                      let url = URL(string: "wss://\(server)/chat") else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: ["origin": webOrigin])
                    try await socket.send(joinFrame(chatChannelID: chatChannelID, token: token, tid: 1))
                    let heartbeat = Task {
                        // The ping counter is owned by this task alone
                        // (no mutable state shared with the receive loop).
                        var pingTid = 2
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                            try? await socket.send(pingFrame(tid: pingTid))
                            pingTid += 1
                        }
                    }
                    defer { heartbeat.cancel() }
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        let (items, shouldClose) = decodeFrame(data, roomID: roomID)
                        for item in items { continuation.yield(item) }
                        if shouldClose { break }
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
