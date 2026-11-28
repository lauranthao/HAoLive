// SixRoomDanmaku.swift
// HAo Live — 六间房 danmaku over the Six Rooms chat WebSocket.
// Protocol from the Pure Live reference (six_room_danmaku.dart),
// re-implemented from scratch; no keys or secrets involved.
//
// Flow: GET https://v.6.cn/{roomId} -> regex
// rid:'{uid}',roomid:'{rid}' takes the uid; GET
// https://v.6.cn/room/getChat.php?rid={uid} -> {websock:
// ["host:port", ...]}. Connect wss://{host:port}, send the login
// frame "command=login\r\nuid={guestId}\r\nencpass=\r\n
// roomid={uid}\r\n" (guestId = 1800000000 + random 8 digits).
// On "command=result / content=login.success", heartbeat with
// "command=sendmessage\r\ncontent=y8vPLwAA\r\n" (first after 1s,
// then every 16s). Chat arrives as command=receivemessage whose
// content is JSON (base64 + raw-DEFLATE when enc=yes, with the
// (+/)/@ alphabet swaps); flag must be 001. content is a list or
// a map; typeID 101/108 is chat (content text, from, fid, tm
// seconds), 110/1413 recurse into nested content.
// NOTE: frames are text lines sent as binary WebSocket messages
// carrying UTF-8 (WebSocketTransport only sends .data). The chat
// server list + login were not verified live from this VM; the
// socket join needs a domestic real-device check.

import Foundation

enum SixRoomDanmaku {
    private static let webOrigin = "https://v.6.cn"
    private static let heartbeatIntervalSeconds: UInt64 = 16

    /// Terminal flags: the server refuses the chat session.
    private static let terminalFlags: Set<String> = [
        "101", "102", "103", "104", "109", "110", "111", "112",
        "113", "114", "204", "305", "306",
    ]

    /// The uid for a room, from its room page HTML.
    static func userID(for roomID: String) async -> String? {
        guard let data = try? await HTTPClient.shared.get("\(webOrigin)/\(roomID)"),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return parseRoomUserID(html, roomID: roomID)
    }

    /// Chat servers for a uid ("host:port" strings).
    static func chatServers(userID: String) async -> [String] {
        let url = SixRoomSite.urlWithQuery("\(webOrigin)/room/getChat.php", [("rid", userID)])
        guard let data = try? await HTTPClient.shared.get(url, headers: headers(roomID: "")),
              let json = JSONValue.parse(data) else { return [] }
        return parseChatServers(json)
    }

    /// Parse the getChat.php payload: websock[] entries must be
    /// host:port on *.6rooms.com. Testable without the network.
    static func parseChatServers(_ json: JSONValue) -> [String] {
        var servers: [String] = []
        for entry in json["websock"].arrayValue {
            let value = (entry.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = value.lastIndex(of: ":") else { continue }
            let host = String(value[..<separator]).lowercased()
            let portString = String(value[value.index(after: separator)...])
            guard let port = Int(portString), port > 0, port <= 65535,
                  host == "6rooms.com" || host.hasSuffix(".6rooms.com"),
                  !servers.contains(value) else { continue }
            servers.append(value)
        }
        return servers
    }

    /// The uid from a room page: rid:'{uid}',roomid:'{rid}' where
    /// the roomid matches. Testable without the network.
    static func parseRoomUserID(_ html: String, roomID: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"rid\s*:\s*['"]([1-9]\d{1,12})['"]\s*,\s*roomid\s*:\s*['"]([1-9]\d{1,11})['"]"#) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges >= 3,
                  let ridRange = Range(match.range(at: 2), in: html),
                  String(html[ridRange]) == roomID,
                  let uidRange = Range(match.range(at: 1), in: html) else { continue }
            return String(html[uidRange])
        }
        return nil
    }

    static func loginFrame(guestID: Int, userID: String) -> Data {
        Data("command=login\r\nuid=\(guestID)\r\nencpass=\r\nroomid=\(userID)\r\n".utf8)
    }

    static func heartbeatFrame() -> Data {
        Data("command=sendmessage\r\ncontent=y8vPLwAA\r\n".utf8)
    }

    /// Split a "key=value\r\n..." frame into fields.
    static func explode(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: "="), separator != line.startIndex else { continue }
            fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return fields
    }

    /// Decode a receivemessage payload: base64 (+ raw-DEFLATE when
    /// enc=yes, with the (+/)/@ alphabet swaps) -> JSON object.
    static func decodePayload(_ fields: [String: String]) -> JSONValue? {
        let raw = fields["content"] ?? ""
        guard !raw.isEmpty else { return nil }
        let encoded: String
        if fields["enc"] == "yes" {
            encoded = raw.replacingOccurrences(of: "(", with: "+")
                .replacingOccurrences(of: ")", with: "/")
                .replacingOccurrences(of: "@", with: "=")
        } else {
            encoded = raw
        }
        guard let bytes = Data(base64Encoded: encoded) else { return nil }
        let plain: Data
        if fields["enc"] == "yes" {
            guard let inflated = ZlibInflate.decompress(bytes, windowBits: -15) else { return nil }
            plain = inflated
        } else {
            plain = bytes
        }
        guard let json = JSONValue.parse(plain), !json.isNull else { return nil }
        return json
    }

    /// Decode HTML entities in a chat text. Nil when empty.
    static func plainText(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        // Numeric / named entities, one pass.
        guard let regex = try? NSRegularExpression(pattern: "&(#x?[0-9a-fA-F]+|[a-zA-Z]+);") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: range) {
            let matchRange = match.range
            result += nsText.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
            let bodyRange = match.range(at: 1)
            let body = nsText.substring(with: bodyRange)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let code = UInt32(String(body.dropFirst(2)), radix: 16), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                } else {
                    result += nsText.substring(with: matchRange)
                }
            } else if body.hasPrefix("#") {
                if let code = UInt32(String(body.dropFirst())), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                } else {
                    result += nsText.substring(with: matchRange)
                }
            } else {
                let named: [String: String] = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "amp": "&"]
                result += named[body] ?? nsText.substring(with: matchRange)
            }
            cursor = matchRange.location + matchRange.length
        }
        result += nsText.substring(from: cursor)
        text = result
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Walk a decoded payload (list or map, depth-capped) and
    /// collect chat items. Testable without the network.
    static func messages(from payload: JSONValue, roomID: String, depth: Int = 0) -> [DanmakuItem] {
        guard depth <= 4 else { return [] }
        if !payload.arrayValue.isEmpty {
            return payload.arrayValue.flatMap { messages(from: $0, roomID: roomID, depth: depth + 1) }
        }
        guard !payload.isNull else { return [] }
        switch payload["typeID"].stringValue ?? "" {
        case "101", "108":
            if let item = chatItem(from: payload, roomID: roomID) { return [item] }
            return []
        case "110", "1413":
            return messages(from: payload["content"], roomID: roomID, depth: depth + 1)
        default:
            return []
        }
    }

    static func chatItem(from raw: JSONValue, roomID: String) -> DanmakuItem? {
        guard let text = plainText(raw["content"].stringValue) else { return nil }
        let user = raw["from"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seconds = raw["tm"].intValue ?? 0
        return DanmakuItem(
            roomID: roomID,
            user: user.isEmpty ? "六间房用户" : user,
            text: text,
            colorHex: "",
            timestamp: seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : Date()
        )
    }

    private static func headers(roomID: String) -> [String: String] {
        [
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Referer": "\(webOrigin)/\(roomID)",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": webOrigin,
        ]
    }

#if !os(Linux)
    /// Live stream of danmaku for a room. Resolves the uid + chat
    /// server, logs in as a guest, heartbeats every 16s, and yields
    /// chat items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let userID = await userID(for: roomID),
                      let server = await chatServers(userID: userID).first,
                      let url = URL(string: "wss://\(server)") else {
                    continuation.finish()
                    return
                }
                let guestID = 1_800_000_000 + Int.random(in: 0..<100_000_000)
                let socket: any DanmakuSocket = WebSocketTransport()
                // Set true by the receive loop on login.success; the
                // deadline task closes the socket when login stalls.
                let loggedIn = LoggedInFlag()
                do {
                    try await socket.connect(url: url, headers: headers(roomID: roomID))
                    try await socket.send(loginFrame(guestID: guestID, userID: userID))
                    let deadline = Task {
                        try? await Task.sleep(for: .seconds(6))
                        if !loggedIn.value {
                            socket.close()
                        }
                    }
                    defer { deadline.cancel() }
                    var heartbeat: Task<Void, Never>?
                    defer { heartbeat?.cancel() }
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        let fields = explode(text)
                        let command = fields["command"] ?? ""
                        if command == "result" {
                            if fields["content"] == "login.success" {
                                loggedIn.value = true
                                heartbeat?.cancel()
                                heartbeat = Task {
                                    try? await Task.sleep(for: .seconds(1))
                                    while !Task.isCancelled {
                                        try? await socket.send(heartbeatFrame())
                                        try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                                    }
                                }
                            }
                            continue
                        }
                        guard command == "receivemessage" else { continue }
                        guard let payload = decodePayload(fields) else { continue }
                        let flag = payload["flag"].stringValue ?? ""
                        if flag != "001" {
                            if terminalFlags.contains(flag) { break }
                            continue
                        }
                        for item in messages(from: payload["content"], roomID: roomID) {
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

/// One-shot flag shared between the receive loop and the login
/// deadline task (same pattern as ResumedFlag in DanmakuSocket).
private final class LoggedInFlag: @unchecked Sendable {
    var value = false
}
