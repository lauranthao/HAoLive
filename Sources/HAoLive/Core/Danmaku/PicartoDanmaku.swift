// PicartoDanmaku.swift
// HAo Live — Picarto danmaku over the chat WebSocket.
// Protocol re-implemented from Pure Live's PicartoDanmaku (Dart).
// Flow: POST https://ptvintern.picarto.tv/ptvapi (GraphQL)
//   {query: "query ($name: String) { generateJwtToken(
//   channel_name: $name) { key } }", variables: {name}}
//   -> data.generateJwtToken.key (a 3-part JWT; verified live
//   from this VM for SilverTsuki), then connect to
//   wss://chat.picarto.tv/chat/token={jwt} with Origin/Referer
//   https://picarto.tv/. Chat frames are JSON: type "c" (or
//   "ct" for tips, "system" for notices) with a "messages" list;
//   a chat line is {t: "c", m: text, n: user, u: userId,
//   k: colour}. A frame with success=false + code JWT_TOKEN
//   means the token was refused — the token is refreshed and
//   the socket reconnected (at most 3 refreshes).
// The socket itself was NOT verified live from this VM (no
// WebSocket client harness here); the token step was.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PicartoDanmaku {
    private static let graphqlURL = "https://ptvintern.picarto.tv/ptvapi"
    private static let maxTokenRefreshes = 3

    /// Request a chat JWT for a channel. Returns nil when the
    /// token is missing or malformed.
    static func requestToken(channelName: String) async -> String? {
        let query = "query ($name: String) { generateJwtToken(channel_name: $name) { key } }"
        let body: [String: Any] = [
            "query": query,
            "variables": ["name": channelName],
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        guard let json = try? await HTTPClient.shared.postJSONParsed(
            graphqlURL,
            jsonData: jsonData,
            headers: ["Origin": "https://picarto.tv", "Referer": "https://picarto.tv/"]
        ) else { return nil }
        guard let key = json["data"]["generateJwtToken"]["key"].stringValue,
              key.split(separator: ".").count == 3 else { return nil }
        return key
    }

    /// Decode one chat frame (JSON text) into danmaku items.
    /// Returns (items, tokenRefused). Only chat lines (t "c" or
    /// absent) yield items; tips, system notices, raids and
    /// subscriptions are ignored — the overlay is chat only.
    /// Testable without the network.
    static func decodeFrame(_ text: String, roomID: String) -> (items: [DanmakuItem], tokenRefused: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = JSONValue.parse(data),
              !json.isNull else { return ([], false) }
        if json["success"].boolValue == false, json["code"].stringValue == "JWT_TOKEN" {
            return ([], true)
        }
        let type = json["type"].stringValue ?? json["t"].stringValue ?? ""
        guard type == "c" || type == "ct" || type == "system" else { return ([], false) }
        guard let payload = json["messages"].arrayValue as [JSONValue]? else { return ([], false) }
        var items: [DanmakuItem] = []
        for line in payload {
            guard let item = parseLine(line, roomID: roomID) else { continue }
            items.append(item)
        }
        return (items, false)
    }

    /// One message line: {t, m, n, u, k}. Tips (frame type "ct"
    /// or a truthy "v") are skipped here — decodeFrame only
    /// forwards chat lines to this parser via type "c" frames,
    /// but a line is also skipped when it is explicitly a tip.
    static func parseLine(_ line: JSONValue, roomID: String) -> DanmakuItem? {
        let type = line["t"].stringValue
        if type != nil, type != "c" { return nil }
        if line["v"].boolValue == true { return nil }
        guard let text = line["m"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let user = line["n"].stringValue ?? ""
        var colorHex = ""
        if let raw = line["k"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: ""),
           raw.count == 6, Int(raw, radix: 16) != nil {
            colorHex = "#\(raw.uppercased())"
        }
        return DanmakuItem(roomID: roomID, user: user, text: text, colorHex: colorHex)
    }

#if !os(Linux)
    /// Live stream of danmaku for a channel. Fetches a chat token,
    /// opens the chat socket, and yields items until cancelled.
    /// A refused token is refreshed and reconnected, at most
    /// maxTokenRefreshes times per run.
    static func stream(channelName: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                var refreshes = 0
                while !Task.isCancelled {
                    guard let token = await requestToken(channelName: channelName) else {
                        break
                    }
                    guard let url = URL(string: "wss://chat.picarto.tv/chat/token=\(token)") else {
                        break
                    }
                    let socket: any DanmakuSocket = WebSocketTransport()
                    var tokenRefused = false
                    do {
                        try await socket.connect(url: url, headers: [
                            "Origin": "https://picarto.tv",
                            "Referer": "https://picarto.tv/",
                        ])
                        while !Task.isCancelled, !tokenRefused {
                            let data = try await socket.receive()
                            guard let text = String(data: data, encoding: .utf8) else { continue }
                            let (items, refused) = decodeFrame(text, roomID: channelName)
                            tokenRefused = refused
                            for item in items {
                                continuation.yield(item)
                            }
                        }
                    } catch {
                        // Connection dropped: the stream simply ends.
                        socket.close()
                        break
                    }
                    socket.close()
                    if tokenRefused {
                        refreshes += 1
                        guard refreshes <= maxTokenRefreshes, !Task.isCancelled else { break }
                        continue
                    }
                    break
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
