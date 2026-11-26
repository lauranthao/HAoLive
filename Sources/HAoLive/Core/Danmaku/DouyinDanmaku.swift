// DouyinDanmaku.swift
// HAo Live — Douyin danmaku channel, re-implemented from the public
// webcast protobuf framing (PushFrame over WebSocket, gzip payloads).
//
// WebSocket: wss://webcast5-ws-web-lf.douyin.com/webcast/im/push/v2/
//   ?app_name=douyin_live&version_code=180800&webcast_sdk_version=1.3.0
//   &update_version_code=1.3.0&compress=gzip&device_platform=web
//   &cookie_enabled=true&browser_language=zh-CN&browser_platform=Win32
//   &browser_name=Mozilla&im_path=/webcast/im/fetch/
//   &device_id={random}&room_id={room id}&heartbeat_interval=30
//
// PushFrame (protobuf):
//   field 1 varint  seq_id, field 2 varint  log_id,
//   field 3 bytes   payload_type ("hb" = heartbeat, "msg" = message),
//   field 4 bytes   payload (gzip-compressed when payload_type is "msg").
//   A heartbeat frame is answered by echoing the same frame back.
// Response (protobuf, inside the decompressed payload):
//   field 1 repeated Message { field 1 bytes method,
//                              field 2 bytes payload }.
// ChatMessage (protobuf, method "WebcastChatMessage"):
//   field 2 User { field 3 bytes nickname },
//   field 3 bytes content.
// Only chat messages yield items; joins/gifts/likes are ignored.

import Foundation

enum DouyinDanmaku {
    static let wsHost = "webcast5-ws-web-lf.douyin.com"

    static func webSocketURL(roomID: String, deviceID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = wsHost
        components.path = "/webcast/im/push/v2/"
        components.queryItems = [
            URLQueryItem(name: "app_name", value: "douyin_live"),
            URLQueryItem(name: "version_code", value: "180800"),
            URLQueryItem(name: "webcast_sdk_version", value: "1.3.0"),
            URLQueryItem(name: "update_version_code", value: "1.3.0"),
            URLQueryItem(name: "compress", value: "gzip"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "browser_language", value: "zh-CN"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "browser_name", value: "Mozilla"),
            URLQueryItem(name: "im_path", value: "/webcast/im/fetch/"),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "room_id", value: roomID),
            URLQueryItem(name: "heartbeat_interval", value: "30"),
        ]
        return components.url
    }

    /// Decode one WebSocket binary frame into danmaku items.
    /// Returns the items and, when the frame was a heartbeat, the frame
    /// itself so the caller can echo it back.
    static func decodeFrame(_ data: Data, roomID: String) -> (items: [DanmakuItem], heartbeatReply: Data?) {
        var reader = ProtoReader(data: data)
        let fields = reader.allFields()
        guard let payloadType = fields[3]?.stringValue,
              let payload = fields[4]?.dataValue else {
            return ([], nil)
        }
        if payloadType == "hb" {
            return ([], data)
        }
        guard payloadType == "msg" else { return ([], nil) }
        guard let response = ZlibInflate.decompress(payload, windowBits: 47) else {
            return ([], nil)
        }
        return (decodeResponse(response, roomID: roomID), nil)
    }

    /// Decode a decompressed Response payload.
    static func decodeResponse(_ data: Data, roomID: String) -> [DanmakuItem] {
        var reader = ProtoReader(data: data)
        var items: [DanmakuItem] = []
        for value in reader.repeatedField(1) {
            guard let messageData = value.dataValue else { continue }
            var messageReader = ProtoReader(data: messageData)
            let messageFields = messageReader.allFields()
            guard messageFields[1]?.stringValue == "WebcastChatMessage",
                  let payload = messageFields[2]?.dataValue,
                  let item = parseChatMessage(payload, roomID: roomID) else { continue }
            items.append(item)
        }
        return items
    }

    /// Parse a WebcastChatMessage payload.
    static func parseChatMessage(_ data: Data, roomID: String) -> DanmakuItem? {
        var reader = ProtoReader(data: data)
        let fields = reader.allFields()
        guard let content = fields[3]?.stringValue, !content.isEmpty else { return nil }
        var user = ""
        if let userData = fields[2]?.dataValue {
            var userReader = ProtoReader(data: userData)
            user = userReader.allFields()[3]?.stringValue ?? ""
        }
        return DanmakuItem(roomID: roomID, user: user, text: content)
    }

#if !os(Linux)
    /// Live stream of danmaku for a room.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = webSocketURL(roomID: roomID, deviceID: UUID().uuidString.replacingOccurrences(of: "-", with: "")) else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: ["Origin": "https://live.douyin.com"])
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        let decoded = decodeFrame(data, roomID: roomID)
                        if let reply = decoded.heartbeatReply {
                            try? await socket.send(reply)
                        }
                        for item in decoded.items {
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
