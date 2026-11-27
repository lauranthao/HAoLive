// KuaishouDanmaku.swift
// HAo Live — Kuaishou danmaku over the web feed WebSocket
// (KuaiShouPack protobuf, proto2). Re-implemented from the wbt5/
// real-url reference handler and its kuaishou.proto; message names
// and enum values cross-checked against the ordinaryroad
// live-chat-client codec.
//
// Flow: GET https://m.gifshow.com/fw/live/{userId} (iPhone Safari
// UA) → the page embeds a wsFeedInfo object (liveStreamId,
// websocketUrls[0], token). Connect to that URL, send
// CS_ENTER_ROOM (200) with token + liveStreamId + pageId, then a
// CS_HEARTBEAT (1) with the current millis every 20s. Chat arrives
// as SC_FEED_PUSH (310) → SCWebFeedPush.commentFeeds (user =
// user.userName, text = content). Gifts, likes and system notices
// are ignored — the overlay is chat only, like Bilibili/Douyin.
//
// NOTE (2026-11-27): the proto and handler were verified against the
// reference source, but NOT yet against Kuaishou's live server from
// this VM — Kuaishou rate-limits this egress IP ("请求过快，请稍后
// 重试"). Needs a domestic real-device check.

import Foundation

enum KuaishouDanmaku {
    static let heartbeatIntervalSeconds: UInt64 = 20
    static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// What the mobile room page gives us to open the feed socket.
    struct FeedInfo {
        let liveStreamId: String
        let wsURL: String
        let token: String
    }

    /// Parse liveStreamId / websocketUrls[0] / token out of the
    /// wsFeedInfo object embedded in m.gifshow.com/fw/live/{userId}.
    static func feedInfo(fromHTML html: String) -> FeedInfo? {
        guard let marker = html.range(of: "wsFeedInfo\":"),
              let brace = html[marker.upperBound...].firstIndex(of: "{"),
              let json = HaoText.extractJSONObject(html, from: brace),
              let root = JSONValue.parse(Data(json.utf8)) else { return nil }
        guard let liveStreamId = root["liveStreamId"].stringValue, !liveStreamId.isEmpty,
              let wsURL = root["websocketUrls"][0].stringValue, !wsURL.isEmpty,
              let token = root["token"].stringValue, !token.isEmpty else { return nil }
        return FeedInfo(liveStreamId: liveStreamId, wsURL: wsURL, token: token)
    }

    /// pageId: 16 random chars from Kuaishou's alphabet + "_" + millis.
    static func pageID() -> String {
        let alphabet = Array("bjectSymhasOwnProp-0123456789ABCDEFGHIJKLMNQRTUVWXYZ_dfgiklquvxz")
        let random = (0..<16).map { _ in String(alphabet.randomElement()!) }.joined()
        return random + "_" + String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// CS_ENTER_ROOM (200): SocketMessage wrapping a CSWebEnterRoom
    /// (token 1, liveStreamId 2, pageId 7). compressionType is
    /// intentionally left unset, as in the reference handler.
    static func enterRoomPacket(liveStreamId: String, token: String, pageID: String) -> Data {
        var enter = ProtoWriter()
        enter.appendStringField(number: 1, value: token)
        enter.appendStringField(number: 2, value: liveStreamId)
        enter.appendStringField(number: 7, value: pageID)
        var message = ProtoWriter()
        message.appendVarintField(number: 1, value: 200)
        message.appendBytesField(number: 3, value: enter.data)
        return message.data
    }

    /// CS_HEARTBEAT (1): SocketMessage wrapping a CSWebHeartbeat
    /// (timestamp 1 = current millis).
    static func heartbeatPacket() -> Data {
        var heartbeat = ProtoWriter()
        heartbeat.appendVarintField(number: 1, value: UInt64(Date().timeIntervalSince1970 * 1000))
        var message = ProtoWriter()
        message.appendVarintField(number: 1, value: 1)
        message.appendBytesField(number: 3, value: heartbeat.data)
        return message.data
    }

    /// Decode one WebSocket frame into danmaku items (usually 0..n).
    /// Only SC_FEED_PUSH (310) yields items; a GZIP-compressed
    /// payload (compressionType 2) is inflated first.
    static func decodeMessage(_ data: Data, roomID: String) -> [DanmakuItem] {
        var reader = ProtoReader(data: data)
        let fields = reader.allFields()
        guard let payloadType = fields[1]?.uintValue, payloadType == 310,
              var payload = fields[3]?.dataValue else { return [] }
        if fields[2]?.uintValue == 2 {
            guard let decompressed = ZlibInflate.decompress(payload, windowBits: 47) else { return [] }
            payload = decompressed
        }
        return parseFeedPush(payload, roomID: roomID)
    }

    /// Decode an SCWebFeedPush payload: commentFeeds only.
    static func parseFeedPush(_ data: Data, roomID: String) -> [DanmakuItem] {
        var reader = ProtoReader(data: data)
        var items: [DanmakuItem] = []
        for value in reader.repeatedField(5) {
            guard let feedData = value.dataValue,
                  let item = parseCommentFeed(feedData, roomID: roomID) else { continue }
            items.append(item)
        }
        return items
    }

    /// Parse one WebCommentFeed: user = user.userName, text = content.
    /// The feed's colour string is only kept when it is a #RRGGBB hex.
    static func parseCommentFeed(_ data: Data, roomID: String) -> DanmakuItem? {
        var reader = ProtoReader(data: data)
        let fields = reader.allFields()
        guard let content = fields[3]?.stringValue, !content.isEmpty else { return nil }
        var user = ""
        if let userData = fields[2]?.dataValue {
            var userReader = ProtoReader(data: userData)
            user = userReader.allFields()[2]?.stringValue ?? ""
        }
        var colorHex = ""
        if let color = fields[6]?.stringValue, color.hasPrefix("#"), color.count == 7 {
            colorHex = color
        }
        return DanmakuItem(roomID: roomID, user: user, text: content, colorHex: colorHex)
    }

    private static func fetchFeedInfo(roomID: String) async -> FeedInfo? {
        guard let data = try? await HTTPClient.shared.get(
            "https://m.gifshow.com/fw/live/\(roomID)",
            headers: ["User-Agent": iPhoneUserAgent]
        ), let html = String(data: data, encoding: .utf8) else { return nil }
        return feedInfo(fromHTML: html)
    }

#if !os(Linux)
    /// Live stream of danmaku for a room. Fetches the feed info from
    /// the mobile page, enters the room on the feed socket, sends a
    /// heartbeat every 20s, and yields items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let info = await fetchFeedInfo(roomID: roomID),
                      let url = URL(string: info.wsURL) else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: [:])
                    try await socket.send(enterRoomPacket(liveStreamId: info.liveStreamId, token: info.token, pageID: pageID()))
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                            try? await socket.send(heartbeatPacket())
                        }
                    }
                    defer { heartbeat.cancel() }
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        for item in decodeMessage(data, roomID: roomID) {
                            continuation.yield(item)
                        }
                    }
                } catch {
                    // Connection dropped: the stream simply ends; the
                    // room view falls back to its sample loop.
                }
                socket.close()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
