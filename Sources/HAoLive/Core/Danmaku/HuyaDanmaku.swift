// HuyaDanmaku.swift
// HAo Live — Huya danmaku over the TAF/TARS websocket channel
// (wss://cdnws.api.huya.com). Protocol reverse-engineered from the
// pure-live-core Go reference and verified live against Huya's
// server from this VM: register answered "注册成功", 151 chat
// messages in 91s from room 485503 (2026-11-27).
//
// Flow: GET https://m.huya.com/{room} (Android UA) → the page embeds
// {"roomProfile": ..., "roomInfo": {"tLiveInfo": {...}}} → lYyid,
// lChannelId/lSubChannelId. Register with a WSUserInfo wrapped in a
// WebSocketCommand (cmd 1); the server answers cmd 2 ("注册成功").
// Heartbeat is a bare UserHeartBeatReq every 30s. Chat arrives as
// cmd 7 → WSPushMessage uri 1400 → MessageNotice (user =
// tUserInfo.sNickName, text = sContent, colour =
// tBulletFormat.iFontColor, -1 = white). Other push URIs (room heat
// 8006, etc.) are ignored.

import Foundation

enum HuyaDanmaku {
    static let host = "cdnws.api.huya.com"
    static let heartbeatIntervalSeconds: UInt64 = 30
    static let androidUserAgent = "Mozilla/5.0 (Linux; Android 5.0; SM-G900P Build/LRX21T) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/75.0.3770.100 Mobile Safari/537.36"

    /// Room ids the TAF channel needs.
    struct RoomIDs {
        let yyid: Int64
        let channelId: Int64
        let subChannelId: Int64
    }

    /// Parse lYyid / lChannelId / lSubChannelId out of m.huya.com/{room}.
    static func roomIDs(fromHTML html: String) -> RoomIDs? {
        guard let marker = html.range(of: "{\"roomProfile\":") else { return nil }
        guard let json = HaoText.extractJSONObject(html, from: marker.lowerBound),
              let root = JSONValue.parse(Data(json.utf8)) else { return nil }
        let liveInfo = root["roomInfo"]["tLiveInfo"]
        guard let yyid = liveInfo["lYyid"].intValue,
              let channelId = liveInfo["tLiveStreamInfo"]["vStreamInfo"]["value"][0]["lChannelId"].intValue,
              let subChannelId = liveInfo["tLiveStreamInfo"]["vStreamInfo"]["value"][0]["lSubChannelId"].intValue else {
            return nil
        }
        return RoomIDs(yyid: Int64(yyid), channelId: Int64(channelId), subChannelId: Int64(subChannelId))
    }

    /// Register packet: WSUserInfo wrapped in a WebSocketCommand (cmd 1).
    /// Verified byte-for-byte against a live Huya session.
    static func registerPacket(yyid: Int64, channelId: Int64, subChannelId: Int64) -> Data {
        var userInfo = TarsWriter()
        userInfo.writeInt(tag: 0, value: yyid)          // lUid
        userInfo.writeBool(tag: 1, value: true)         // bAnonymous
        userInfo.writeString(tag: 2, value: "")         // sGuid
        userInfo.writeString(tag: 3, value: "")         // sToken
        userInfo.writeInt(tag: 4, value: channelId)     // lTid
        userInfo.writeInt(tag: 5, value: subChannelId)  // lSid
        userInfo.writeInt(tag: 6, value: yyid)          // lGroupId
        userInfo.writeInt(tag: 7, value: 3)             // lGroupType
        var command = TarsWriter()
        command.writeInt(tag: 0, value: 1)              // ewsCmdRegisterReq
        command.writeBytes(tag: 1, value: userInfo.data) // vData
        return command.data
    }

    /// Heartbeat packet: a bare UserHeartBeatReq (not wrapped in a
    /// WebSocketCommand). Verified byte-for-byte against a live session.
    static func heartbeatPacket() -> Data {
        var userId = TarsWriter()
        userId.writeInt(tag: 0, value: 0)                          // lUid
        userId.writeString(tag: 1, value: "")                     // sGuid
        userId.writeString(tag: 2, value: "")                     // sToken
        userId.writeString(tag: 3, value: "webh5&1.0.0&websocket") // sHuyaUA
        userId.writeString(tag: 4, value: "")                     // sCookie
        var request = TarsWriter()
        request.writeStructBegin(tag: 0)                           // tId
        request.appendRaw(userId.data)
        request.writeStructEnd()
        request.writeInt(tag: 1, value: 0)                         // lTid
        request.writeInt(tag: 2, value: 0)                         // lSid
        request.writeInt(tag: 3, value: 0)                         // lShortTid
        request.writeInt(tag: 4, value: 0)                         // lPid
        request.writeBool(tag: 5, value: true)                     // bWatchVideo
        request.writeInt(tag: 6, value: 1)                         // eLineType
        return request.data
    }

    /// Decode one WebSocket frame into danmaku items (usually 0 or 1).
    static func decodeMessage(_ frame: Data, roomID: String) -> [DanmakuItem] {
        var command = TarsReader(data: frame)
        guard let cmdType = command.readInt(tag: 0), cmdType == 7 else { return [] }
        guard let payload = command.readBytes(tag: 1) else { return [] }
        var push = TarsReader(data: payload)
        guard let uri = push.readInt(tag: 1), uri == 1400 else { return [] }
        guard let message = push.readBytes(tag: 2) else { return [] }
        guard let item = parseMessageNotice(message, roomID: roomID) else { return [] }
        return [item]
    }

    /// Parse a MessageNotice payload: user = tUserInfo.sNickName,
    /// text = sContent, colour = tBulletFormat.iFontColor (-1 = white).
    static func parseMessageNotice(_ data: Data, roomID: String) -> DanmakuItem? {
        var notice = TarsReader(data: data)
        var user = ""
        if var sender = notice.readStruct(tag: 0) {
            user = sender.readString(tag: 2) ?? ""
            guard notice.skipStructBody() else { return nil }
        }
        guard let text = notice.readString(tag: 3), !text.isEmpty else { return nil }
        var color = 0xFFFFFF
        if var format = notice.readStruct(tag: 6) {
            if let fontColor = format.readInt(tag: 0), fontColor != -1 {
                color = Int(fontColor & 0xFFFFFF)
            }
            guard notice.skipStructBody() else { return nil }
        }
        return DanmakuItem(
            roomID: roomID,
            user: user,
            text: text,
            colorHex: String(format: "#%06X", color)
        )
    }

    private static func fetchRoomIDs(roomID: String) async -> RoomIDs? {
        guard let data = try? await HTTPClient.shared.get(
            "https://m.huya.com/\(roomID)",
            headers: ["User-Agent": androidUserAgent]
        ), let html = String(data: data, encoding: .utf8) else { return nil }
        return roomIDs(fromHTML: html)
    }

#if !os(Linux)
    /// Live stream of danmaku for a room. Fetches the room ids from
    /// the mobile page, registers on the TAF channel, sends a
    /// heartbeat every 30s, and yields items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let ids = await fetchRoomIDs(roomID: roomID) else {
                    continuation.finish()
                    return
                }
                let url = URL(string: "wss://\(host)/")!
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: [:])
                    try await socket.send(registerPacket(yyid: ids.yyid, channelId: ids.channelId, subChannelId: ids.subChannelId))
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
