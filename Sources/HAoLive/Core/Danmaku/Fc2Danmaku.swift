// Fc2Danmaku.swift
// HAo Live — FC2 Live danmaku over the control WebSocket.
// Pure Live's fc2_live_danmaku.dart, re-implemented from
// scratch. Same control seat as playback (Fc2ControlSession):
// connect wss://…/control/channels/<id>?control_token=<token>
// with Cookie l_ortkn=<orz> and Origin https://live.fc2.com,
// wait for connect_complete, heartbeat every 30 s.
//
// Comment frames look like:
//   {"name":"comment","arguments":{"comments":[
//     {"from":"…","comment":"text","history":"0",
//      "name":"…","date":"…","comment_color":"#E63D37",
//      "anonymous":"0","is_mobile":"0", …}]}}
// "comment" items with history "1" are replay, not live.
// "ng_comment" carries the server's mute lists (admin_ng /
// shared_ng_level / ng_comments add/remove, keyword vs user).
// "user_count" carries pc/mobile viewer counts (ignored here).
// "control_disconnection" closes the channel.
// Live WS verified on this VM 2026-11-28 (real comment frames
// arrived; see the file header of Fc2ControlSession.swift).
// The frame decoder, plain-text stripper and NG filter are
// pure and testable without the network.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum Fc2Danmaku {
    static let heartbeatIntervalSeconds: UInt64 = 30

    /// A mutable NG (mute) list, from "ng_comment" frames.
    struct NGList {
        var users = Set<String>()
        var keywords: [String] = []
        var level: Int = 0
        var adminNG: Bool = false

        mutating func apply(_ payload: JSONValue) {
            if let value = payload["admin_ng"].intValue {
                adminNG = value == 1
            }
            if let value = payload["shared_ng_level"].intValue {
                level = value
            }
            for value in payload["ng_comments"].arrayValue {
                guard let type = value["ng_type"].intValue,
                      let action = value["ng_action"].intValue else { continue }
                if type == 2, let id = value["ng_target_id"].stringValue, !id.isEmpty {
                    if action == 1 { users.insert(id) } else { users.remove(id) }
                }
                if type == 1, let keyword = value["ng_target_id"].stringValue, !keyword.isEmpty {
                    if action == 1, !keywords.contains(keyword) {
                        keywords.append(keyword)
                    } else if action == 0 {
                        keywords.removeAll { $0 == keyword }
                    }
                }
            }
        }

        func blocks(user: String, text: String) -> Bool {
            if adminNG { return true }
            if !user.isEmpty && users.contains(user) { return true }
            return keywords.contains { !$0.isEmpty && text.contains($0) }
        }
    }

    /// FC2's comment colour map (Pure Live's Fc2CommentType).
    static let colors: [String: String] = [
        "red": "E63D37", "pink": "E13396", "orange": "DC7611",
        "yellow": "E1AC00", "green": "33BD4A", "cyan": "1B94C7",
        "blue": "4472F3", "purple": "B84AC5",
    ]

    /// Strip HTML tags and decode the common entities. Pure.
    static func plainText(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode one comment payload into items. Skips replay
    /// (history "1") and NG-blocked comments. Pure function.
    static func comments(from payload: JSONValue, roomID: String, ng: NGList) -> [DanmakuItem] {
        var items: [DanmakuItem] = []
        for value in payload["comments"].arrayValue {
            guard value["history"].stringValue != "1" else { continue }
            let text = plainText(value["comment"].stringValue ?? "")
            guard !text.isEmpty else { continue }
            let user = plainText(value["name"].stringValue ?? "")
            guard !ng.blocks(user: user, text: text) else { continue }
            let color = (value["comment_color"].stringValue ?? "")
                .replacingOccurrences(of: "#", with: "")
            let timestamp: Date
            if let millis = value["date"].intValue, millis > 0 {
                timestamp = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            } else {
                timestamp = Date()
            }
            items.append(DanmakuItem(
                roomID: roomID,
                user: user,
                text: text,
                colorHex: color,
                timestamp: timestamp
            ))
        }
        return items
    }

#if !os(Linux)
    /// Live stream of danmaku for one FC2 channel. Opens its own
    /// control seat (separate from any playback seat).
    static func stream(channelID: String, http: HTTPClient) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let grant = try? await Fc2ControlSession.controlGrant(channelID: channelID, http: http) else {
                    continuation.finish()
                    return
                }
                var components = URLComponents(url: grant.webSocket, resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "control_token", value: grant.controlToken)]
                guard let url = components?.url else {
                    continuation.finish()
                    return
                }
                var request = URLRequest(url: url)
                request.setValue(Fc2ControlSession.origin, forHTTPHeaderField: "Origin")
                request.setValue(Fc2ControlSession.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("l_ortkn=\(grant.orz)", forHTTPHeaderField: "Cookie")
                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()
                defer { socket.cancel(with: .normalClosure, reason: nil) }
                var ng = NGList()
                var idCounter = 0
                func nextID() -> Int { idCounter += 1; return idCounter }
                func send(name: String, arguments: [String: Any]) async {
                    let frame: [String: Any] = ["name": name, "arguments": arguments, "id": nextID()]
                    guard let data = try? JSONSerialization.data(withJSONObject: frame, options: []),
                          let text = String(data: data, encoding: .utf8) else { return }
                    try? await socket.send(.string(text))
                }
                let heartbeat = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                        await send(name: "heartbeat", arguments: [:])
                    }
                }
                defer { heartbeat.cancel() }
                while !Task.isCancelled {
                    do {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let data = text.data(using: .utf8),
                              let json = JSONValue.parse(data),
                              let name = json["name"].stringValue else { continue }
                        let arguments = json["arguments"]
                        switch name {
                        case "comment":
                            for item in comments(from: arguments, roomID: channelID, ng: ng) {
                                continuation.yield(item)
                            }
                        case "ng_comment":
                            ng.apply(arguments)
                        case "user_count":
                            continue
                        case "control_disconnection":
                            throw LiveSiteError.networkUnavailable
                        default:
                            continue
                        }
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
