// TwitcastingDanmaku.swift
// HAo Live — TwitCasting danmaku over the comment pubsub channel.
// Flow (Pure Live's TwitcastingDanmaku, ported): the room's movie id
// comes from streamserver.php; POST https://twitcasting.tv/
// eventpubsuburl.php (form movie_id) returns {"url": "wss://..."}; the
// socket then pushes JSON frames — a single object or an array — and
// type == "comment" frames carry message + author.name/screenName.
// No heartbeat is sent (the reference sends none). Anonymous, no login.

import Foundation

enum TwitcastingDanmaku {
    private static let origin = "https://twitcasting.tv"

    /// Resolve the live movie id for a channel. Nil when the channel
    /// is offline or the streamserver response carries no movie.
    static func movieID(forChannel channel: String) async -> Int? {
        guard let json = try? await HTTPClient.shared.getJSON(
            "\(origin)/streamserver.php?target=\(channel)&mode=client&player=pc_web"),
              json["movie"]["live"].boolValue == true,
              let movieID = json["movie"]["id"].intValue, movieID > 0 else { return nil }
        return movieID
    }

    /// The pubsub WebSocket URL for a movie id. Nil when the endpoint
    /// answers anything but a wss://*.twitcasting.tv URL.
    static func socketURL(forMovieID movieID: Int) async -> URL? {
        guard let json = try? await HTTPClient.shared.postFormJSON(
            "\(origin)/eventpubsuburl.php",
            fields: ["movie_id": "\(movieID)"],
            headers: ["Referer": "\(origin)/", "Origin": origin]),
              let urlString = json["url"].stringValue,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "wss",
              let host = url.host?.lowercased(),
              host == "twitcasting.tv" || host.hasSuffix(".twitcasting.tv") else { return nil }
        return url
    }

    /// Decode one WebSocket text frame into danmaku items (usually 0
    /// or 1). Pure function, testable without the network. Duplicate
    /// comment ids are dropped by the caller via `seenIDs`.
    static func decodeFrame(_ text: String, roomID: String, seenIDs: inout Set<String>) -> [DanmakuItem] {
        guard let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return [] }
        let events = json.arrayValue.isEmpty && json.isNull ? [] : (json.arrayValue.isEmpty ? [json] : json.arrayValue)
        var out: [DanmakuItem] = []
        for event in events {
            guard event["type"].stringValue == "comment",
                  let message = event["message"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { continue }
            if let id = event["id"].stringValue, !id.isEmpty {
                guard seenIDs.insert(id).inserted else { continue }
                if seenIDs.count > 400 { seenIDs.removeFirst() }
            }
            let author = event["author"]
            let name = HaoText.firstNonEmpty(author["name"].stringValue, author["screenName"].stringValue) ?? "TwitCasting"
            out.append(DanmakuItem(roomID: roomID, user: name, text: message))
        }
        return out
    }

#if !os(Linux)
    /// Live stream of danmaku for a channel (roomID is the channel
    /// name). Ends quietly when the channel is offline, the pubsub
    /// endpoint answers nothing usable, or the socket drops.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let channel = roomID.lowercased()
                guard let movieID = await movieID(forChannel: channel),
                      let url = await socketURL(forMovieID: movieID) else {
                    continuation.finish()
                    return
                }
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: [
                        "Referer": "\(origin)/",
                        "Origin": origin,
                    ])
                    var seenIDs = Set<String>()
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        for item in decodeFrame(text, roomID: roomID, seenIDs: &seenIDs) {
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
