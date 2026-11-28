// TwitchDanmaku.swift
// HAo Live — Twitch chat over IRC WebSocket (wss://irc-ws.chat.twitch.tv).
// Pure Live's twitch_danmaku.dart, re-implemented from scratch.
// Anonymous login: PASS SCHMOOPIIE + NICK justinfan<random> — no
// account, no token. Verified live from this VM 2026-11-28: the
// server answered 001 "Welcome, GLHF!", the JOIN was accepted, and
// PRIVMSG frames with tags arrived for #qttsix.
//
// Wire format: one text frame per IRC line. Tags arrive as
// @key=value;key=value (escapes \s space, \: ;, \r, \n, \\).
// PRIVMSG yields a chat item (display-name, color, tmi-sent-ts).
// USERNOTICE system messages are skipped — HAoLive's DanmakuItem
// has no notice type. CLEARMSG / CLEARCHAT retractions are skipped
// for the same reason. PING is answered with PONG.
// The socket uses URLSessionWebSocketTask text frames directly:
// Twitch IRC expects TEXT frames, and the shared WebSocketTransport
// only sends binary (.data) frames.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TwitchDanmaku {
    static let host = "irc-ws.chat.twitch.tv"
    static let heartbeatIntervalSeconds: UInt64 = 40

    /// Parse IRC lines into chat items. Pure function, testable
    /// without the network.
    static func parseMessages(_ text: String, roomID: String) -> [DanmakuItem] {
        var items: [DanmakuItem] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var tags: [String: String] = [:]
            var rest = line[...]
            if line.hasPrefix("@") {
                if let space = line.firstIndex(of: " ") {
                    for entry in line[line.index(after: line.startIndex)..<space].split(separator: ";") {
                        let parts = entry.split(separator: "=", maxSplits: 1)
                        if parts.count == 2 {
                            tags[String(parts[0])] = decodeTagValue(String(parts[1]))
                        }
                    }
                    rest = line[line.index(after: space)...]
                }
            }
            // Retractions and notices carry no chat text for this UI.
            if line.contains(" CLEARMSG ") || line.contains(" CLEARCHAT ") { continue }
            if line.contains(" USERNOTICE ") { continue }
            guard line.contains(" PRIVMSG ") else { continue }
            guard let messageStart = line.range(of: " :", options: [], range: line.range(of: " PRIVMSG ")!.upperBound..<line.endIndex) else { continue }
            let content = String(line[messageStart.upperBound...])
            guard !content.isEmpty else { continue }
            let displayName = tags["display-name"]?.trimmingCharacters(in: .whitespaces)
            let user: String
            if let displayName, !displayName.isEmpty {
                user = displayName
            } else if rest.hasPrefix(":"), let bang = rest.firstIndex(of: "!") {
                // Prefix is ":nick!nick@nick.tmi.twitch.tv".
                user = String(rest[rest.index(after: rest.startIndex)..<bang])
            } else {
                user = "Twitch"
            }
            let colorText = (tags["color"] ?? "").replacingOccurrences(of: "#", with: "")
            let colorValue = Int(colorText, radix: 16) ?? 0xFFFFFF
            let timestamp: Date
            if let millis = tags["tmi-sent-ts"].flatMap({ Int($0) }) {
                timestamp = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            } else {
                timestamp = Date()
            }
            items.append(DanmakuItem(
                roomID: roomID,
                user: user,
                text: content,
                colorHex: String(format: "#%06X", colorValue),
                timestamp: timestamp
            ))
        }
        return items
    }

    /// Unescape an IRC tag value (\s \n \r \: \\).
    static func decodeTagValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s", with: " ")
            .replacingOccurrences(of: "\\:", with: ";")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

#if !os(Linux)
    /// Live stream of danmaku for a channel login. Logs in
    /// anonymously as justinfan<random>, joins #<login>, answers
    /// PING with PONG, and yields PRIVMSG items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let login = roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !login.isEmpty, let url = URL(string: "wss://\(host)/") else {
                    continuation.finish()
                    return
                }
                var request = URLRequest(url: url)
                request.setValue(HTTPClient.shared.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()
                let nick = "justinfan\(1000 + Int.random(in: 0..<99000))"
                func send(_ text: String) async {
                    try? await socket.send(.string(text))
                }
                await send("PASS SCHMOOPIIE")
                await send("NICK \(nick)")
                await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
                await send("JOIN #\(login)")
                let heartbeat = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                        try? await socket.send(.string("PING :tmi.twitch.tv"))
                    }
                }
                defer { heartbeat.cancel() }
                while !Task.isCancelled {
                    do {
                        switch try await socket.receive() {
                        case .string(let text):
                            if text.hasPrefix("PING") {
                                try? await socket.send(.string(text.replacingOccurrences(of: "PING", with: "PONG").trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                            for item in parseMessages(text, roomID: roomID) {
                                continuation.yield(item)
                            }
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) {
                                for item in parseMessages(text, roomID: roomID) {
                                    continuation.yield(item)
                                }
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        break
                    }
                }
                socket.cancel(with: .normalClosure, reason: nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
