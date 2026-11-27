// DouyinSite.swift
// HAo Live — real Douyin adapter (anonymous, no login).
// Verified live from this VM 2026-11-26:
//   room page GET https://live.douyin.com/{web_rid} — the page embeds
//   an escaped JSON blob (Next.js RSC payload) containing:
//     homeStore.recommendCategoryData: [{partition: {id_str, title},
//       has_parent_node, second_node, first_node}] — the category list
//     roomStore.roomInfo: {room: {id_str, status (2 = live, 4 = ended),
//       title, user_count_str}, web_rid, anchor: {nickname,
//       avatar_thumb: {url_list}}, web_stream_url: {...} | null}
//   Stream URLs — Pure Live's route (the room probed 2026-11-27 was
//   offline, so web_stream_url was null and no live room's stream
//   keys could be verified from this VM; needs a device):
//     modern: web_stream_url.live_core_sdk_data.pull_data.stream_data
//       (a JSON string; data: {qualityKey: {main: {flv, hls}}})
//     legacy: web_stream_url.hls_pull_url_map and .hls_pull_url
//       (qualityKey -> URL string or {url_list: [...]})
//   Quality keys are joined by key, never by position; "ao" is
//   audio-only and is skipped. Only HLS URLs are offered (AVPlayer
//   cannot play FLV); stream_data's main.flv is the FLV-engine input
//   for later.
//   Quality keys: FULL_HD1 原画, HD1 超清, SD1 高清, SD2 标清.
// NOT verifiable from this VM — the webcast JSON APIs all refuse
// this egress IP (feed: "url doesn't match", enter: empty reply,
// room list: 404), so recommend / category rooms / search call those
// APIs and return what they get (usually nothing here). They need a
// China-network device to confirm. The room page path above is the
// part that is verified: opening a known room id works end to end.
// Danmaku: WebSocket + protobuf PushFrame (see DouyinDanmaku); the WS
// room_id is the room's id_str, resolved from the room page.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DouyinSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .douyin
    private let http = HTTPClient.shared

    private static let webBase = "https://live.douyin.com"

    /// Pull-URL quality key -> display name.
    private static let qualityNames: [String: String] = [
        "FULL_HD1": "原画", "HD1": "超清", "SD1": "高清", "SD2": "标清",
    ]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let html = try await pageHTML(path: "")
        guard let homeStore = Self.extractEscapedObject(marker: "homeStore", in: html) else {
            return []
        }
        return Self.categories(fromHomeStore: homeStore)
    }

    /// Pure parser for homeStore.recommendCategoryData.
    /// Testable without the network.
    static func categories(fromHomeStore homeStore: JSONValue) -> [LiveCategory] {
        homeStore["recommendCategoryData"].arrayValue.compactMap { item in
            let partition = item["partition"]
            guard let id = partition["id_str"].stringValue,
                  let title = partition["title"].stringValue, !title.isEmpty else { return nil }
            return LiveCategory(id: "douyin-\(id)", platform: .douyin, name: title, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        // Webcast feed API; refused from this VM — returns [] here.
        let url = "\(Self.webBase)/webcast/web/feed/?aid=6383&device_platform=web&count=20&version_code=180800&webcast_sdk_version=1.3.0&update_version_code=1.3.0"
        guard let json = try? await http.getJSON(url),
              json["status_code"].intValue == 0 else { return [] }
        return json["data"]["data"].arrayValue.compactMap(Self.room(fromFeedItem:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        let categoryID = category.id.dropFirst("douyin-".count)
        let url = "\(Self.webBase)/webcast/room/list/?aid=6383&device_platform=web&category_id=\(categoryID)&count=20"
        guard let json = try? await http.getJSON(url),
              json["status_code"].intValue == 0 else { return [] }
        return json["data"]["data"].arrayValue.compactMap(Self.room(fromFeedItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    /// Douyin web search. Unverified from this VM (the aweme search
    /// API needs a signature); parsed defensively, returns [] on failure.
    private func search(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://www.douyin.com/aweme/v1/web/search/item/?device_platform=webapp&aid=6383&keyword=\(encoded)&search_source=tab_search&count=10"
        guard let json = try? await http.getJSON(url, headers: ["Referer": "https://www.douyin.com/"]) else {
            return []
        }
        return json["aweme_list"].arrayValue.compactMap { item in
            guard item["is_live"].boolValue == true,
                  let roomID = item["room_id"].stringValue ?? item["aweme_id"].stringValue,
                  !roomID.isEmpty else { return nil }
            let author = item["author"]
            return LiveRoom(
                id: "douyin-\(roomID)",
                platform: .douyin,
                roomID: roomID,
                title: item["desc"].stringValue ?? "",
                anchorName: author["nickname"].stringValue ?? "",
                anchorAvatarURL: URL(string: author["avatar_thumb"]["url_list"][0].stringValue ?? ""),
                coverURL: URL(string: item["video"]["cover"]["url_list"][0].stringValue ?? ""),
                categoryName: nil,
                viewerCount: 0,
                isLive: true
            )
        }
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let roomInfo = try await roomInfo(for: roomID)
        return Self.room(fromRoomInfo: roomInfo, webRID: roomID)
    }

    // MARK: - Play URLs

    func playURLs(roomID: String) async throws -> [PlayStream] {
        let roomInfo = try await roomInfo(for: roomID)
        let streamURL = roomInfo["web_stream_url"]
        guard !streamURL.isNull else { return [] } // offline: no stream
        return Self.streams(fromStreamURL: streamURL)
    }

    /// Pure parser for the whole web_stream_url object: the modern
    /// live_core_sdk_data.pull_data.stream_data payload (a JSON string;
    /// per quality key, main.hls) joined by quality key with the
    /// legacy hls_pull_url_map and hls_pull_url maps. Audio-only
    /// ("ao") keys are skipped — they carry no video track.
    /// Testable without the network.
    static func streams(fromStreamURL streamURL: JSONValue) -> [PlayStream] {
        // Modern payload: stream_data is a JSON string
        // {"data": {qualityKey: {main: {flv, hls}}}}.
        var modernHLS: [String: String] = [:]
        if let text = streamURL["live_core_sdk_data"]["pull_data"]["stream_data"].stringValue,
           let data = text.data(using: .utf8),
           let json = JSONValue.parse(data) {
            for (key, value) in json["data"].objectValue {
                if let hls = value["main"]["hls"].stringValue, !hls.isEmpty {
                    modernHLS[key.lowercased()] = hls
                }
            }
        }
        // Legacy maps: qualityKey -> URL string or {url_list: [...]}.
        var legacyHLS: [String: String] = [:]
        for mapKey in ["hls_pull_url_map", "hls_pull_url"] {
            for (key, value) in streamURL[mapKey].objectValue {
                let urlString = value.stringValue ?? value["url_list"][0].stringValue
                if let urlString, !urlString.isEmpty {
                    legacyHLS[key.lowercased()] = urlString
                }
            }
        }
        // Display names from resolution_name (keys matched
        // case-insensitively), else the known key table, else the raw key.
        var resolutionNames: [String: String] = [:]
        for (key, value) in streamURL["resolution_name"].objectValue {
            if let name = value.stringValue, !name.isEmpty {
                resolutionNames[key.lowercased()] = name
            }
        }
        // All quality keys, joined by key (never by position).
        var keys = Array(modernHLS.keys)
        for key in legacyHLS.keys where !keys.contains(key) {
            keys.append(key)
        }
        // Known rank first (原画 > 超清 > 高清 > 标清), then the rest.
        let rank = ["full_hd1": 0, "hd1": 1, "sd1": 2, "sd2": 3]
        keys.sort { (rank[$0] ?? 99) < (rank[$1] ?? 99) }
        var streams: [PlayStream] = []
        for key in keys {
            if key == "ao" { continue } // audio-only pull URL, no video
            guard let urlString = modernHLS[key] ?? legacyHLS[key],
                  let url = URL(string: urlString) else { continue }
            let display = resolutionNames[key]
                ?? Self.qualityNames[key.uppercased()]
                ?? key
            streams.append(PlayStream(url: url, quality: display, line: "主线路"))
        }
        return streams
    }

    // MARK: - Danmaku

    func sampleDanmaku(roomID: String) async -> [DanmakuItem] {
        [] // real channel below; never show fake lines as live danmaku
    }

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                // The WS wants the room's internal id_str, not the
                // web_rid from the page URL; resolve it first.
                var wsRoomID = roomID
                if let roomInfo = try? await self.roomInfo(for: roomID),
                   let idStr = roomInfo["room"]["id_str"].stringValue, !idStr.isEmpty {
                    wsRoomID = idStr
                }
                #if !os(Linux)
                for await item in DouyinDanmaku.stream(roomID: wsRoomID) {
                    continuation.yield(item)
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Page helpers

    private func pageHTML(path: String) async throws -> String {
        let data = try await http.get("\(Self.webBase)/\(path)")
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return html
    }

    /// roomStore.roomInfo for a web_rid. The room page embeds
    /// roomStore twice — an empty initial store, then the hydrated
    /// one — so the first populated copy wins; a page whose store
    /// never hydrates has no room to show.
    private func roomInfo(for webRID: String) async throws -> JSONValue {
        let html = try await pageHTML(path: webRID)
        let stores = HaoText.extractAllEscapedJSONObjects(html, marker: "roomStore").compactMap { text -> JSONValue? in
            guard let data = text.data(using: .utf8) else { return nil }
            return JSONValue.parse(data)
        }
        guard let roomInfo = Self.roomInfo(fromRoomStores: stores) else {
            throw LiveSiteError.roomNotFound(webRID)
        }
        return roomInfo
    }

    /// Pick the hydrated roomInfo from the page's roomStore objects.
    /// Testable without the network.
    static func roomInfo(fromRoomStores stores: [JSONValue]) -> JSONValue? {
        for store in stores {
            let roomInfo = store["roomInfo"]
            if !roomInfo.isNull, !roomInfo["room"].isNull {
                return roomInfo
            }
        }
        return nil
    }

    /// Extract an object from the page's escaped JSON blob.
    /// Testable without the network.
    static func extractEscapedObject(marker: String, in html: String) -> JSONValue? {
        guard let text = HaoText.extractEscapedJSONObject(html, marker: marker),
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return json
    }

    // MARK: - Mapping helpers

    /// Pure parser for a roomInfo object. Testable without the network.
    static func room(fromRoomInfo info: JSONValue, webRID: String) -> LiveRoom {
        let room = info["room"]
        let anchor = info["anchor"]
        return LiveRoom(
            id: "douyin-\(webRID)",
            platform: .douyin,
            roomID: webRID,
            title: room["title"].stringValue ?? "",
            anchorName: anchor["nickname"].stringValue ?? "",
            anchorAvatarURL: URL(string: anchor["avatar_thumb"]["url_list"][0].stringValue ?? ""),
            coverURL: nil,
            categoryName: nil,
            viewerCount: Int(room["user_count_str"].stringValue ?? "") ?? 0,
            isLive: room["status"].intValue == 2
        )
    }

    /// Pure parser for a feed item (recommend / category rooms).
    /// Testable without the network.
    static func room(fromFeedItem item: JSONValue) -> LiveRoom? {
        // Feed items carry the room under "room" with owner under "owner".
        let room = item["room"]
        guard !room.isNull else { return nil }
        let roomID = room["id_str"].stringValue ?? ""
        guard !roomID.isEmpty else { return nil }
        let owner = item["owner"].isNull ? room["owner"] : item["owner"]
        return LiveRoom(
            id: "douyin-\(roomID)",
            platform: .douyin,
            roomID: roomID,
            title: room["title"].stringValue ?? "",
            anchorName: owner["nickname"].stringValue ?? "",
            anchorAvatarURL: URL(string: owner["avatar_thumb"]["url_list"][0].stringValue ?? ""),
            coverURL: URL(string: room["cover"]["url_list"][0].stringValue ?? ""),
            categoryName: nil,
            viewerCount: room["user_count"].intValue ?? 0,
            isLive: room["status"].intValue == 2
        )
    }
}
