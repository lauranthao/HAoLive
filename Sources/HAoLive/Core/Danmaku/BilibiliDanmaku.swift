// BilibiliDanmaku.swift
// HAo Live — Bilibili danmaku channel, re-implemented from the public
// binary protocol (16-byte header, op codes, protover 2 = zlib).
// Auth needs the token from getDanmuInfo; when that endpoint is
// risk-controlled (-352 from this VM) the well-known default host is
// used with an empty token — the server still accepts it for receiving.
//
// Packet: [total length u32 BE][header length u16 BE = 16]
//         [version u16 BE][op u32 BE][seq u32 BE][body]
//   version 0 = plain JSON, 1 = heartbeat reply (popularity int),
//           2 = zlib-compressed packets, 3 = brotli (not used:
//           protover 2 keeps the server on zlib).
//   op 2 = heartbeat, 3 = heartbeat reply, 5 = command, 7 = auth,
//      8 = auth reply.
// Command body (op 5) is JSON; DANMU_MSG info is:
//   info[0] = [0, 1, 25, color, ...], info[1] = text,
//   info[2] = [uid, uname, ...].

import Foundation

enum BilibiliDanmaku {
    static let defaultHost = "broadcastlv.chat.bilibili.com"
    static let defaultWSSPort = 2245
    static let heartbeatIntervalSeconds: UInt64 = 30

    static func frame(op: Int32, body: Data, version: Int32 = 1) -> Data {
        var data = Data()
        data.appendUInt32BE(UInt32(16 + body.count))
        data.appendUInt16BE(16)
        data.appendUInt16BE(UInt16(version))
        data.appendInt32BE(op)
        data.appendUInt32BE(1)
        data.append(body)
        return data
    }

    static func authPacket(roomID: Int, token: String, protover: Int = 2) -> Data {
        let body = "{\"uid\":0,\"roomid\":\(roomID),\"protover\":\(protover),\"platform\":\"web\",\"type\":2,\"key\":\"\(token)\"}"
        return frame(op: 7, body: Data(body.utf8))
    }

    static func heartbeatPacket() -> Data {
        frame(op: 2, body: Data())
    }

    /// Decode one WebSocket message (it may pack several packets, and a
    /// zlib packet unpacks into more packets) into danmaku items.
    static func decodeMessage(_ data: Data, roomID: String) -> [DanmakuItem] {
        var items: [DanmakuItem] = []
        decodePackets(data, roomID: roomID, into: &items)
        return items
    }

    private static func decodePackets(_ data: Data, roomID: String, into items: inout [DanmakuItem]) {
        var offset = 0
        while offset + 16 <= data.count {
            let total = Int(data.uint32BE(at: offset))
            guard total >= 16, offset + total <= data.count else { break }
            let version = Int(data.uint16BE(at: offset + 6))
            let op = Int(data.uint32BE(at: offset + 8))
            let body = data.subdata(in: (offset + 16)..<(offset + total))
            if op == 5 {
                if version == 2 {
                    if let decompressed = ZlibInflate.decompress(body, windowBits: 15) {
                        decodePackets(decompressed, roomID: roomID, into: &items)
                    }
                } else if version == 0 || version == 1 {
                    if let item = parseCommand(body, roomID: roomID) {
                        items.append(item)
                    }
                }
                // version 3 (brotli) is never requested: protover 2.
            }
            offset += total
        }
    }

    /// Parse one op-5 command body. Only DANMU_MSG yields an item.
    static func parseCommand(_ body: Data, roomID: String) -> DanmakuItem? {
        guard let json = JSONValue.parse(body),
              json["cmd"].stringValue == "DANMU_MSG" else { return nil }
        let info = json["info"]
        guard let text = info[1].stringValue, !text.isEmpty else { return nil }
        let user = info[2][1].stringValue ?? ""
        let color = info[0][3].intValue ?? 0xFFFFFF
        return DanmakuItem(
            roomID: roomID,
            user: user,
            text: text,
            colorHex: String(format: "#%06X", color)
        )
    }

#if !os(Linux)
    /// Live stream of danmaku for a room. Connects to the given host
    /// (from getDanmuInfo) or the default host, authenticates, sends a
    /// heartbeat every 30s, and yields items until cancelled.
    static func stream(roomID: String, token: String, host: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let socket: any DanmakuSocket = WebSocketTransport()
                let url = URL(string: "wss://\(host):\(defaultWSSPort)/sub")!
                do {
                    try await socket.connect(url: url, headers: ["Origin": "https://live.bilibili.com"])
                    try await socket.send(authPacket(roomID: Int(roomID) ?? 0, token: token))
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
