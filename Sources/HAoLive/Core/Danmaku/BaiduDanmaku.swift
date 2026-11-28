// BaiduDanmaku.swift
// HAo Live — Baidu Live danmaku by polling the HLS chat playlist.
// The detail response hands out chat list URLs (chat_msg_hls_url /
// reliable_msg_hls_url / host_msg_hls_url); each list is an m3u8
// whose segments are gzip-compressed JSON batches:
//   {"list":[{"messages":[{"type":0,"msgid":…,"create_time":…,
//     "content":"{…}","from_user":"{…}"}]}]}
// Chat text lives in content.content (message_type "0") or in a
// link title (message_type "3"); other types (images, etc.) and
// gifts are skipped. No login, no secret.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BaiduDanmakuArgs {
    var chatListURL: String
    var reliableListURL: String = ""
    var hostListURL: String = ""
    var pollIntervalSeconds: Int = 5
    var roomID: String = ""
}

enum BaiduDanmaku {
    /// Poll the chat playlists until cancelled. Yields chat items.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let args = await BaiduSite.danmakuArgs(roomID: roomID),
                      !args.chatListURL.isEmpty else {
                    continuation.finish()
                    return
                }
                var seen = Set<String>()
                let interval = UInt64(min(max(args.pollIntervalSeconds, 1), 10))
                while !Task.isCancelled {
                    for listURL in [args.chatListURL, args.reliableListURL, args.hostListURL] where !listURL.isEmpty {
                        if Task.isCancelled { break }
                        await pollList(listURL, seen: &seen, roomID: roomID, continuation: continuation)
                    }
                    try? await Task.sleep(for: .seconds(Int(interval)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func pollList(_ listURL: String, seen: inout Set<String>, roomID: String, continuation: AsyncStream<DanmakuItem>.Continuation) async {
        guard let data = try? await HTTPClient.shared.get(listURL, headers: ["Accept": "application/json, text/plain, */*", "Origin": "https://live.baidu.com", "Referer": "https://live.baidu.com/"]),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U"),
              let base = URL(string: listURL) else { return }
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            guard let segment = URL(string: value, relativeTo: base)?.absoluteString,
                  seen.insert(segment).inserted else { continue }
            if seen.count > 512, let first = seen.first { seen.remove(first) }
            await fetchSegment(segment, roomID: roomID, continuation: continuation)
            if Task.isCancelled { return }
        }
    }

    private static func fetchSegment(_ segment: String, roomID: String, continuation: AsyncStream<DanmakuItem>.Continuation) async {
        guard let data = try? await HTTPClient.shared.get(segment, headers: ["Accept": "application/json, text/plain, */*", "Origin": "https://live.baidu.com", "Referer": "https://live.baidu.com/"]) else { return }
        let decoded = decodeSegment(data, roomID: roomID)
        for item in decoded {
            continuation.yield(item)
        }
    }

    /// Decompress (gzip, up to two layers) + parse one segment into
    /// chat items. Testable without the network.
    static func decodeSegment(_ bytes: Data, roomID: String) -> [DanmakuItem] {
        var data = bytes
        for _ in 0..<2 {
            guard data.count >= 2, data[0] == 0x1f, data[1] == 0x8b,
                  let inflated = ZlibInflate.decompress(data, windowBits: 47) else { break }
            data = inflated
        }
        guard let json = JSONValue.parse(data) else { return [] }
        var out: [DanmakuItem] = []
        for entry in json["list"].arrayValue {
            for message in entry["messages"].arrayValue {
                if let item = decodeMessage(message, roomID: roomID) { out.append(item) }
            }
        }
        return out
    }

    /// One chat message: type 0 only; content/from_user are JSON
    /// objects or JSON-encoded strings.
    static func decodeMessage(_ message: JSONValue, roomID: String) -> DanmakuItem? {
        guard message["type"].intValue == 0 else { return nil }
        guard let content = jsonObject(message["content"]) else { return nil }
        let fromUser = jsonObject(message["from_user"]) ?? JSONValue.null
        let user = HaoText.firstNonEmpty(fromUser["uname"].stringValue, fromUser["name"].stringValue) ?? "百度用户"
        guard let text = chatText(content), !text.isEmpty else { return nil }
        return DanmakuItem(
            roomID: roomID,
            user: user,
            text: text,
            timestamp: message["create_time"].intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        )
    }

    static func chatText(_ content: JSONValue) -> String? {
        let type = content["message_type"].stringValue ?? content["type"].stringValue ?? ""
        var text: String?
        switch type {
        case "0":
            text = content["content"].stringValue
        case "3":
            text = jsonObject(content["message_body"])?["link"]["title"].stringValue
        case "1", "2", "4", "5":
            return nil
        default:
            text = content["content"].stringValue
        }
        if text == nil {
            text = jsonObject(content["message_body"])?["txt"]["word"].stringValue
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A JSON object, or a JSON-encoded string holding one.
    static func jsonObject(_ value: JSONValue) -> JSONValue? {
        if !value.objectValue.isEmpty { return value }
        guard let text = value.stringValue, !text.isEmpty,
              (text.hasPrefix("{") || text.hasPrefix("[")),
              let data = text.data(using: .utf8),
              let parsed = JSONValue.parse(data) else { return nil }
        return parsed
    }
}
