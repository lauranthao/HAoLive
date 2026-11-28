// SeventeenLiveDanmaku.swift
// HAo Live — 17LIVE danmaku over the Ably realtime channel.
// Re-implemented from Pure Live's SeventeenLiveDanmaku.
//
// Flow: POST https://api-dsa.17app.co/api/v1/messenger/auth
// (empty JSON body) -> {provider: 1, token}; connect to
//   wss://17media.realtime.ably.net/?format=json&heartbeats=true
//   &v=3&access_token={token}
// (fallbacks 17-media-{a,b,c}-fallback.ably-realtime.com).
// Ably JSON protocol: action 4 (CONNECTED) -> send
// {"action":10,"channel":roomId} (ATTACH); action 11 (ATTACHED)
// means joined; action 15 (MESSAGE) carries messages[] whose
// data is base64 gzip JSON — type 3 is chat
// (commentMsg.body.comment, user.displayName, body.textColor),
// type 38 is a viewer-count update (ignored). Action 13
// re-attaches (max 3 refusals); action 9 with a 40140-40149 code
// is a token error (clear the token, re-authorize); action 17
// re-authorizes in place; action 6 closes the channel.
// NOT yet verified against the live server from this VM (the
// api-dsa host 502s from this egress) — needs a domestic
// real-device check.

import Foundation

enum SeventeenLiveDanmaku {
    static let primaryHost = "17media.realtime.ably.net"
    static let fallbackHosts = [
        "17-media-a-fallback.ably-realtime.com",
        "17-media-b-fallback.ably-realtime.com",
        "17-media-c-fallback.ably-realtime.com",
    ]
    static let ablyProvider = 1
    static let maxRefusals = 3
    static let joinTimeoutSeconds: UInt64 = 10

    /// POST /api/v1/messenger/auth. Nil when the provider is not
    /// Ably (1) or the token is missing.
    static func requestToken() async -> String? {
        guard let body = "{}".data(using: .utf8) else { return nil }
        guard let json = try? await HTTPClient.shared.postJSONParsed(
            "https://api-dsa.17app.co/api/v1/messenger/auth",
            jsonData: body,
            headers: [
                "Origin": "https://17.live",
                "Referer": "https://17.live/",
            ]) else { return nil }
        guard json["provider"].intValue == ablyProvider else { return nil }
        let token = json["token"].stringValue ?? ""
        guard !token.isEmpty, token.count <= 4096 else { return nil }
        return token
    }

    static func socketURL(host: String, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "heartbeats", value: "true"),
            URLQueryItem(name: "v", value: "3"),
            URLQueryItem(name: "access_token", value: token),
        ]
        return components.url
    }

    /// Parse one Ably MESSAGE (action 15) payload into chat items.
    /// Each message data field is base64 gzip JSON. Testable
    /// without the network.
    static func chatItems(fromMessages raw: JSONValue, roomID: String) -> [DanmakuItem] {
        var items: [DanmakuItem] = []
        for entry in raw.arrayValue {
            guard let payload = payload(fromDataField: entry["data"]),
                  let item = chatItem(fromPayload: payload, id: entry["id"].stringValue ?? "", roomID: roomID) else {
                continue
            }
            items.append(item)
        }
        return items
    }

    /// Decode a base64 gzip JSON data field. Testable without the network.
    static func payload(fromDataField value: JSONValue) -> JSONValue? {
        guard let encoded = value.stringValue, !encoded.isEmpty,
              let compressed = Data(base64Encoded: encoded),
              let decompressed = ZlibInflate.decompress(compressed, windowBits: 47),
              let json = JSONValue.parse(decompressed) else { return nil }
        return json
    }

    /// Parse one decompressed message payload. Type 3 = chat;
    /// anything else is ignored (type 38 is a viewer count).
    /// Testable without the network.
    static func chatItem(fromPayload payload: JSONValue, id: String, roomID: String) -> DanmakuItem? {
        guard payload["type"].intValue == 3 else { return nil }
        let comment = payload["commentMsg"]
        guard comment["isDirty"].boolValue != true,
              comment["isDirtyWord"].boolValue != true,
              comment["isDirtyUser"].boolValue != true else { return nil }
        let body = comment["body"]
        let text = body["comment"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        let user = comment["user"]
        let name = user["displayName"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var colorHex = ""
        if let colorText = body["textColor"].stringValue?
            .replacingOccurrences(of: "#", with: ""), colorText.count == 6 {
            colorHex = "#\(colorText.uppercased())"
        }
        return DanmakuItem(
            id: id.isEmpty ? UUID().uuidString : "17live:\(id)",
            roomID: roomID,
            user: name.isEmpty ? (user["openID"].stringValue ?? "") : name,
            text: text,
            colorHex: colorHex
        )
    }

    /// True when an Ably ERROR frame is a token error
    /// (40140-40149): the token must be re-authorized.
    static func isTokenError(_ error: JSONValue) -> Bool {
        guard let code = error["code"].intValue else { return false }
        return code >= 40140 && code < 40150
    }

#if !os(Linux)
    /// Live stream of danmaku for a room (liveStreamID). Fetches
    /// an Ably token, connects (primary host first, then the
    /// fallbacks), attaches to the room channel, and yields chat
    /// items until cancelled.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                var token = ""
                var attempt = 0
                while !Task.isCancelled {
                    if token.isEmpty {
                        guard let fresh = await requestToken() else {
                            continuation.finish()
                            return
                        }
                        token = fresh
                    }
                    let host = attempt == 0 ? primaryHost : fallbackHosts[(attempt - 1) % fallbackHosts.count]
                    let outcome = await runSocket(host: host, token: token, roomID: roomID, continuation: continuation)
                    switch outcome {
                    case .ended:
                        continuation.finish()
                        return
                    case .tokenExpired:
                        token = ""
                        attempt = 0
                    case .dropped:
                        attempt += 1
                        try? await Task.sleep(for: .seconds(min(attempt, 8)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum SocketOutcome {
        /// Channel closed for good (or the task was cancelled).
        case ended
        /// The token died; fetch a fresh one and reconnect.
        case tokenExpired
        /// Dropped mid-stream; retry with backoff.
        case dropped
    }

    /// One Ably socket attempt.
    private static func runSocket(host: String, token: String, roomID: String, continuation: AsyncStream<DanmakuItem>.Continuation) async -> SocketOutcome {
        guard let url = socketURL(host: host, token: token) else { return .ended }
        let socket: any DanmakuSocket = WebSocketTransport()
        let state = SocketState(roomID: roomID)
        do {
            try await socket.connect(url: url, headers: ["Origin": "https://17.live"])
            // Join watchdog: attach must confirm within 10s.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Int(joinTimeoutSeconds)))
                if !state.joined { socket.close() }
            }
            defer { watchdog.cancel() }
            while !Task.isCancelled {
                let data = try await socket.receive()
                guard let text = String(data: data, encoding: .utf8),
                      let frame = JSONValue.parse(Data(text.utf8)),
                      !frame.isNull else { continue }
                let action = frame["action"].intValue ?? -1
                let channel = frame["channel"].stringValue ?? ""
                let ours = channel.isEmpty || channel == roomID
                switch action {
                case 4: // CONNECTED: attach to the room channel.
                    try? await socket.send(Data(attachMessage(roomID: roomID).utf8))
                case 11: // ATTACHED
                    guard ours else { continue }
                    state.refusals = 0
                    state.joined = true
                case 13: // attach refused: re-attach, max 3 times.
                    guard ours else { continue }
                    state.refusals += 1
                    if state.refusals > maxRefusals { return .dropped }
                    try? await socket.send(Data(attachMessage(roomID: roomID).utf8))
                case 15: // MESSAGE
                    guard ours else { continue }
                    for item in chatItems(fromMessages: frame["messages"], roomID: roomID) {
                        continuation.yield(item)
                    }
                case 9: // ERROR
                    if isTokenError(frame["error"]) {
                        return .tokenExpired
                    }
                    return .dropped
                case 6: // CLOSED
                    return .ended
                case 17: // re-authorize requested
                    if let fresh = await requestToken() {
                        try? await socket.send(Data(reauthorizeMessage(token: fresh).utf8))
                    } else {
                        return .tokenExpired
                    }
                default:
                    break
                }
            }
            return .ended
        } catch {
            socket.close()
            return .dropped
        }
    }

    private static func attachMessage(roomID: String) -> String {
        "{\"action\":10,\"channel\":\"\(roomID)\"}"
    }

    private static func reauthorizeMessage(token: String) -> String {
        "{\"action\":17,\"auth\":{\"accessToken\":\"\(token)\"}}"
    }

    /// Mutable per-attempt state shared with the watchdog.
    private final class SocketState: @unchecked Sendable {
        let roomID: String
        var joined = false
        var refusals = 0
        init(roomID: String) { self.roomID = roomID }
    }
#endif
}
