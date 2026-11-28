// SoopDanmaku.swift
// HAo Live — SOOP danmaku over the Afreeca chat WebSocket.
// Protocol re-implemented from Pure Live's SoopDanmaku (Dart).
// Chat endpoint comes from player_live_api's CHANNEL (see
// SoopSite.channelData): host is CHDOMAIN, or derived from CHIP
// as chat-<IPv4 as uppercase hex>.sooplive.co.kr; the TLS port
// is CHPT+1 (CHPT is the plain port — WSS to the plain port
// stalls in the TLS handshake); path /Websocket/{bjid};
// chatNo is CHANNEL.CHATNO.
//
// Packets are text frames built from ESC (\x1b\x09) + a 4-digit
// service code + a 6-digit body length + \x0c-separated fields:
//   connect: ESC 0001 000006 00 \x0c\x0c\x0c 16 \x0c
//   join:    ESC 0002 <len6> 00 \x0c {chatNo} \x0c\x0c\x0c\x0c\x0c
//   heartbeat (every 20 s): ESC 0000 000001 00 \x0c
// Incoming frames carry a 14-byte header: ESC TAB, service (4
// ASCII digits), body length (6 ASCII digits), 2 bytes; service
// 5 is chat, its body split by \x0c gives fields[1] = comment,
// fields[6] = user name.
//
// NOT verified live from this VM: the socket needs a live room's
// CHATNO/CHDOMAIN, and this VM has no WebSocket client harness
// for it (WebSocketTransport is Apple-only). Packet builders and
// the decoder are pure and unit-shaped like HuyaDanmaku's, but
// the live handshake is unconfirmed — see the report.

import Foundation

enum SoopDanmaku {
    static let heartbeatIntervalSeconds: UInt64 = 20

    private static let esc = "\u{1b}\u{09}"
    private static let field = "\u{0c}"

    /// WSS chat URL for a CHANNEL object (Pure Live's
    /// buildDanmakuWebSocketUrl). Testable without the network.
    static func webSocketURL(channel: JSONValue, roomID: String) -> URL? {
        let room = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return nil }
        var host = channel["CHDOMAIN"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty {
            host = secureChatHost(fromIPv4: channel["CHIP"].stringValue ?? "")
        }
        guard let plainPort = channel["CHPT"].intValue, plainPort > 0, plainPort < 65535,
              !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = plainPort + 1
        components.path = "/Websocket/\(room)"
        return components.url
    }

    /// chat-<HEX>.sooplive.co.kr from a dotted IPv4 address
    /// (each octet as two uppercase hex digits).
    static func secureChatHost(fromIPv4 rawIP: String) -> String {
        let octets = rawIP.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return "" }
        let hex = octets.map { String(format: "%02X", $0) }.joined()
        return "chat-\(hex).sooplive.co.kr"
    }

    /// Connect packet: ESC 0001 000006 00 + 3 fields + "16" + field.
    static func connectPacket() -> Data {
        Data("\(esc)000100000600\(field)\(field)\(field)16\(field)".utf8)
    }

    /// Join packet for a chatNo (byte length of chatNo + 6, padded
    /// to 6 digits).
    static func joinPacket(chatNo: String) -> Data {
        let size = chatNo.utf8.count + 6
        let sizeText = String(format: "%06d", size)
        return Data("\(esc)0002\(sizeText)00\(field)\(chatNo)\(field)\(field)\(field)\(field)\(field)".utf8)
    }

    /// Heartbeat packet (every 20 s).
    static func heartbeatPacket() -> Data {
        Data("\(esc)000000000100\(field)".utf8)
    }

    /// Decode one WebSocket frame into danmaku items. Frames may
    /// pack several 14-byte-header packets; only service 5 yields
    /// chat. Testable without the network.
    static func decodeMessage(_ data: Data, roomID: String) -> [DanmakuItem] {
        var items: [DanmakuItem] = []
        let headerLength = 14
        var offset = 0
        while offset + headerLength <= data.count {
            guard data[offset] == 0x1b, data[offset + 1] == 0x09 else { return items }
            guard let serviceText = String(data: data.subdata(in: (offset + 2)..<(offset + 6)), encoding: .ascii),
                  let service = Int(serviceText),
                  let lengthText = String(data: data.subdata(in: (offset + 6)..<(offset + 12)), encoding: .ascii),
                  let bodyLength = Int(lengthText), bodyLength >= 0 else { return items }
            let packetEnd = offset + headerLength + bodyLength
            guard packetEnd <= data.count else { return items }
            if service == 5 {
                let body = data.subdata(in: (offset + headerLength)..<packetEnd)
                if let item = parseChatPacket(body, roomID: roomID) {
                    items.append(item)
                }
            }
            offset = packetEnd
        }
        return items
    }

    /// One service-5 body: \x0c-separated fields, fields[1] is the
    /// comment, fields[6] is the user name.
    static func parseChatPacket(_ body: Data, roomID: String) -> DanmakuItem? {
        let parts = body.split(separator: 0x0c)
        let fields = parts.map { String(data: Data($0), encoding: .utf8) ?? "" }
        guard fields.count > 6 else { return nil }
        let comment = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let user = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty, !user.isEmpty,
              comment != "-1", comment != "1", !comment.contains("|") else { return nil }
        return DanmakuItem(roomID: roomID, user: user, text: comment)
    }

#if !os(Linux)
    /// Live stream of danmaku for a room. Fetches the chat endpoint
    /// from player_live_api, connects, joins the chat room, sends a
    /// heartbeat every 20 s, and yields items until cancelled.
    /// NOTE: URLSessionWebSocketTask cannot set the 'chat'
    /// subprotocol Pure Live requests; the handshake goes without
    /// it. If the server refuses, the stream simply ends.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let channel = try? await SoopSite.channelData(roomID: roomID),
                      let chatNo = channel["CHATNO"].stringValue, !chatNo.isEmpty,
                      let url = webSocketURL(channel: channel, roomID: roomID) else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: [
                        "Origin": "https://play.sooplive.co.kr",
                        "Referer": "https://www.sooplive.co.kr/",
                    ])
                    try await socket.send(connectPacket())
                    try? await Task.sleep(for: .milliseconds(200))
                    try await socket.send(joinPacket(chatNo: chatNo))
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
