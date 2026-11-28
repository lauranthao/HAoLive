// ShowroomDanmaku.swift
// HAo Live — SHOWROOM danmaku over the comment server.
// Flow (Pure Live's ShowroomDanmaku, ported): GET
// /api/live/live_info?room_id= gives bcsvr_host + bcsvr_key; open
// wss://{host}/ with Origin https://www.showroom-live.com; on open
// send "SUB\t{key}" and a "PING\tshowroom" every 60s. Chat arrives
// as text frames "MSG\t{key}\t{json}" where the JSON has t == "1"
// for chat (cm = text, ac = account name, u = user id,
// created_at = unix seconds, cl = level). Frames for another key
// are ignored. Anonymous, no login.

import Foundation

enum ShowroomDanmaku {
    private static let origin = "https://www.showroom-live.com"
    private static let pingIntervalSeconds: UInt64 = 60

    /// The comment server for a room: (host, key) from live_info.
    /// Empty host/key means no danmaku channel for this room.
    static func commentServer(roomID: String) async -> (host: String, key: String) {
        let trimmed = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: Int?
        if let numeric = Int(trimmed), numeric > 0 {
            id = numeric
        } else {
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            let status = try? await HTTPClient.shared.getJSON("\(origin)/api/room/status?room_url_key=\(encoded)")
            id = status?["room_id"].intValue
        }
        guard let id, id > 0,
              let json = try? await HTTPClient.shared.getJSON("\(origin)/api/live/live_info?room_id=\(id)") else {
            return (host: "", key: "")
        }
        return (host: ShowroomSite.commentHost(json["bcsvr_host"].stringValue),
                key: ShowroomSite.commentKey(json["bcsvr_key"].stringValue))
    }

    /// Decode one text frame into danmaku items (usually 0 or 1).
    /// Pure function, testable without the network.
    static func decodeFrame(_ text: String, key: String, roomID: String) -> [DanmakuItem] {
        guard text.hasPrefix("MSG\t") else { return [] }
        let rest = String(text.dropFirst("MSG\t".count))
        guard let separator = rest.firstIndex(of: "\t") else { return [] }
        let frameKey = String(rest[..<separator])
        guard frameKey == key else { return [] }
        let payload = String(rest[rest.index(after: separator)...])
        guard let data = payload.data(using: .utf8),
              let json = JSONValue.parse(data),
              json["t"].stringValue == "1",
              let message = json["cm"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return [] }
        return [DanmakuItem(roomID: roomID, user: json["ac"].stringValue ?? "", text: message)]
    }

#if !os(Linux)
    /// Live stream of danmaku for a room (roomID is the numeric room
    /// id or a room_url_key). Ends quietly when the room has no
    /// comment server or the socket drops.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let server = await commentServer(roomID: roomID)
                guard !server.host.isEmpty, !server.key.isEmpty,
                      let url = URL(string: "wss://\(server.host)/") else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: ["Origin": origin])
                    try await socket.send(Data("SUB\t\(server.key)".utf8))
                    let ping = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(Int(pingIntervalSeconds)))
                            try? await socket.send(Data("PING\tshowroom".utf8))
                        }
                    }
                    defer { ping.cancel() }
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        for item in decodeFrame(text, key: server.key, roomID: roomID) {
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
