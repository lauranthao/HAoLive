// DouyuDanmaku.swift
// HAo Live — Douyu danmaku channel, re-implemented from the public
// STT text protocol over WebSocket (Pure Live's DouyuApi.danmakuServer:
// wss://danmuproxy.douyu.com:8506). Build 19: the old raw-TCP route
// (openbarrage.douyutv.com:8601) is dead — the server RSTs the
// connection on login (verified live against a 33M-viewer room, 0
// messages), so no Douyu room showed any danmaku. The STT packets
// are unchanged; only the transport and the heartbeat changed.
//
// Wire packet (12-byte header + body + NUL):
//   [length u32 LE][length u32 LE][type u16 LE = 689]
//   [encrypt u8 = 0][reserved u8 = 0][body][0x00]
//   length = 8 + body bytes (including the trailing NUL).
// Body is STT text: key@=value/key2@=value2/  with @ -> @A and / -> @S
// escaping inside values. One receive may hold several packets;
// a packet may also arrive split across receives, so the parser
// keeps a leftover buffer.
//
// Messages: loginreq (type@=loginreq/roomid@={id}/),
// joingroup (type@=joingroup/rid@={id}/gid@=-9999/),
// mrkl (type@=mrkl/ heartbeat),
// chatmsg carries nn@= (user) and txt@= (text).

import Foundation

enum DouyuDanmaku {
    /// Pure Live's danmaku server (DouyuApi.danmakuServer).
    static let danmakuServer = "wss://danmuproxy.douyu.com:8506"
    static let heartbeatIntervalSeconds: UInt64 = 45

    // MARK: - STT text

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "@", with: "@A")
            .replacingOccurrences(of: "/", with: "@S")
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "@S", with: "/")
            .replacingOccurrences(of: "@A", with: "@")
    }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { key, value in "\(key)@=\(escape(value))/" }.joined()
    }

    static func decode(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in text.split(separator: "/", omittingEmptySubsequences: true) {
            let pair = part.split(separator: "@=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            out[String(pair[0])] = unescape(String(pair[1]))
        }
        return out
    }

    // MARK: - Wire packets

    static func packet(_ body: String) -> Data {
        var bodyData = Data(body.utf8)
        bodyData.append(0)
        var data = Data()
        let length = UInt32(8 + bodyData.count)
        data.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(689).littleEndian) { Array($0) })
        data.append(0) // encrypt
        data.append(0) // reserved
        data.append(bodyData)
        return data
    }

    static func loginPacket(roomID: String) -> Data {
        packet(encode([("type", "loginreq"), ("roomid", roomID)]))
    }

    static func joinGroupPacket(roomID: String) -> Data {
        packet(encode([("type", "joingroup"), ("rid", roomID), ("gid", "-9999")]))
    }

    static func keepalivePacket() -> Data {
        packet(encode([("type", "mrkl")]))
    }

    /// Split received bytes into complete STT messages. Returns the
    /// messages and any incomplete tail to prepend to the next chunk.
    /// Offset-based: Data indices are not 0-based after a removeFirst,
    /// so the buffer is never mutated — subdata ranges stay valid.
    static func parseFrames(_ data: Data, leftover: Data = Data()) -> (messages: [[String: String]], leftover: Data) {
        let buffer = leftover + data
        var messages: [[String: String]] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let length = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian)
            // length counts the bytes after the first length field.
            guard length >= 8, buffer.count - offset >= 4 + length else { break }
            // packet: [length u32][length u32][type u16][encrypt u8][reserved u8][body + NUL]
            let bodyStart = offset + 12
            var bodyEnd = offset + 4 + length
            if bodyEnd > bodyStart {
                if buffer[bodyEnd - 1] == 0 { bodyEnd -= 1 }
                let body = buffer.subdata(in: bodyStart..<bodyEnd)
                if let text = String(data: body, encoding: .utf8) {
                    messages.append(decode(text))
                }
            }
            offset += 4 + length
        }
        // Copy the tail into a fresh Data so its indices start at 0.
        let rest = offset < buffer.count ? Data(buffer[offset..<buffer.count]) : Data()
        return (messages, rest)
    }

    /// One chatmsg's fields -> a danmaku item. Other message types
    /// (loginres, uenter, ...) return nil.
    static func chatItem(from fields: [String: String], roomID: String) -> DanmakuItem? {
        guard fields["type"] == "chatmsg",
              let text = fields["txt"], !text.isEmpty else { return nil }
        return DanmakuItem(
            roomID: roomID,
            user: fields["nn"] ?? "",
            text: text
        )
    }

#if !os(Linux)
    /// Live stream of danmaku for a room over the WebSocket barrage
    /// server (Pure Live's DouyuDanmakuConnection: one anonymous
    /// WebSocket, join packets on open, `mrkl` heartbeat every 45 s).
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let socket: any DanmakuSocket = WebSocketTransport()
                let url = URL(string: danmakuServer)!
                do {
                    try await socket.connect(url: url, headers: [:])
                    try await socket.send(loginPacket(roomID: roomID))
                    try await socket.send(joinGroupPacket(roomID: roomID))
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                            try? await socket.send(keepalivePacket())
                        }
                    }
                    defer { heartbeat.cancel() }
                    var leftover = Data()
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        let parsed = parseFrames(data, leftover: leftover)
                        leftover = parsed.leftover
                        for fields in parsed.messages {
                            if let item = chatItem(from: fields, roomID: roomID) {
                                continuation.yield(item)
                            }
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
