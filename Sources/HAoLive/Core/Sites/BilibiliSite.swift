// BilibiliSite.swift
// HAo Live — real Bilibili adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-26:
//   room info   GET api.live.bilibili.com/room/v1/Room/get_info
//   room list   GET api.live.bilibili.com/room/v3/area/getRoomList
//               (sort_type=online; the sort_type_online value returns
//               an empty list — use "online")
//   areas       GET api.live.bilibili.com/room/v1/Area/getList
//   search      GET api.bilibili.com/x/web-interface/search/type
//               (needs Referer: https://search.bilibili.com/ or it
//               answers with an HTML error page)
//   play info   GET api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo
//   danmaku info GET api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo
//               (risk-controlled from this VM: code -352; the adapter
//               falls back to the default danmaku host with an empty
//               token, which the server still accepts for receiving)
//
// Playback rule (Pure Live's "actual effective quality"): anonymous
// requests are silently downgraded — the server answers current_qn
// (250 = 超清 here) even when qn=10000 was asked. Only the quality
// the server actually returned gets a stream; accept_qn entries
// without URLs are never offered. Only HLS streams are returned:
// AVPlayer cannot play FLV.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BilibiliSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .bilibili
    private let http = HTTPClient.shared

    private static let apiBase = "https://api.live.bilibili.com"
    private static let searchReferer = "https://search.bilibili.com/"

    /// qn -> display name, from the play-info g_qn_desc list when
    /// present; this table is the documented fallback.
    private static let qualityNames: [Int: String] = [
        30000: "杜比", 20000: "4K", 15000: "2K", 10000: "原画",
        400: "蓝光", 250: "超清", 150: "高清", 80: "流畅",
    ]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.apiBase)/room/v1/Area/getList")
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return Self.categories(fromList: json["data"])
    }

    /// Pure parser for the getList data array (parent areas).
    /// Testable without the network.
    static func categories(fromList data: JSONValue) -> [LiveCategory] {
        data.arrayValue.compactMap { area in
            guard let id = area["id"].stringValue,
                  let name = area["name"].stringValue, !name.isEmpty else { return nil }
            return LiveCategory(id: "bili-\(id)", platform: .bilibili, name: name, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await roomList(parentAreaID: 0, areaID: 0)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        // Category ids are "bili-{parent area id}".
        let parentID = Int(category.id.dropFirst("bili-".count)) ?? 0
        return try await roomList(parentAreaID: parentID, areaID: 0)
    }

    private func roomList(parentAreaID: Int, areaID: Int, page: Int = 1) async throws -> [LiveRoom] {
        let url = "\(Self.apiBase)/room/v3/area/getRoomList?platform=web&parent_area_id=\(parentAreaID)&cate_id=0&area_id=\(areaID)&sort_type=online&page=\(page)&page_size=30"
        let json = try await http.getJSON(url)
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]["list"].arrayValue.map(Self.room(fromListItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://api.bilibili.com/x/web-interface/search/type?search_type=live_room&keyword=\(encoded)&page=1&page_size=20"
        let json = try await http.getJSON(url, headers: ["Referer": Self.searchReferer])
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]["result"].arrayValue.map(Self.room(fromSearchRoomItem:))
    }

    /// Pure parser for one live_room search result.
    /// Testable without the network.
    static func room(fromSearchRoomItem item: JSONValue) -> LiveRoom {
        LiveRoom(
            id: "bili-\(item["roomid"].stringValue ?? "")",
            platform: .bilibili,
            roomID: item["roomid"].stringValue ?? "",
            title: HaoText.stripTags(item["title"].stringValue ?? ""),
            anchorName: HaoText.stripTags(item["uname"].stringValue ?? ""),
            anchorAvatarURL: Self.httpURL(item["uface"].stringValue),
            coverURL: Self.httpURL(HaoText.firstNonEmpty(item["cover"].stringValue, item["pic"].stringValue)),
            categoryName: item["cate_name"].stringValue,
            viewerCount: item["online"].intValue ?? 0,
            isLive: item["live_status"].intValue == 1
        )
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://api.bilibili.com/x/web-interface/search/type?search_type=live_user&keyword=\(encoded)&page=1&page_size=20"
        let json = try await http.getJSON(url, headers: ["Referer": Self.searchReferer])
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]["result"].arrayValue.compactMap(Self.room(fromSearchUserItem:))
    }

    /// Pure parser for one live_user search result.
    /// Testable without the network.
    static func room(fromSearchUserItem item: JSONValue) -> LiveRoom? {
        guard let roomID = item["roomid"].stringValue, !roomID.isEmpty else { return nil }
        return LiveRoom(
            id: "bili-\(roomID)",
            platform: .bilibili,
            roomID: roomID,
            title: HaoText.stripTags(item["cate_name"].stringValue ?? ""),
            anchorName: HaoText.stripTags(item["uname"].stringValue ?? ""),
            anchorAvatarURL: Self.httpURL(item["uface"].stringValue),
            coverURL: nil,
            categoryName: item["cate_name"].stringValue,
            viewerCount: 0,
            isLive: item["live_status"].intValue == 1
        )
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let json = try await http.getJSON("\(Self.apiBase)/room/v1/Room/get_info?room_id=\(roomID)")
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        guard let room = Self.room(fromInfo: json["data"]) else { throw LiveSiteError.roomNotFound(roomID) }
        return room
    }

    /// Pure parser for a get_info data object. Testable without the network.
    static func room(fromInfo data: JSONValue) -> LiveRoom? {
        guard let id = data["room_id"].stringValue else { return nil }
        return LiveRoom(
            id: "bili-\(id)",
            platform: .bilibili,
            roomID: id,
            title: data["title"].stringValue ?? "",
            anchorName: data["anchor_info"]["base_info"]["uname"].stringValue ?? "",
            anchorAvatarURL: Self.httpURL(data["anchor_info"]["base_info"]["face"].stringValue),
            coverURL: Self.httpURL(HaoText.firstNonEmpty(data["user_cover"].stringValue, data["keyframe"].stringValue)),
            categoryName: data["area_name"].stringValue,
            viewerCount: data["online"].intValue ?? 0,
            isLive: data["live_status"].intValue == 1
        )
    }

    // MARK: - Play URLs

    func playURLs(roomID: String) async throws -> [PlayStream] {
        let url = "\(Self.apiBase)/xlive/web-room/v2/index/getRoomPlayInfo?room_id=\(roomID)&protocol=0,1&format=0,1,2&codec=0,1&qn=10000&platform=web&ptype=8"
        let json = try await http.getJSON(url)
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        let playurl = json["data"]["playurl_info"]["playurl"]
        guard !playurl.isNull else { return [] } // room offline
        return Self.streams(fromPlayInfo: playurl)
    }

    /// Pure parser for the play-info payload: quality names from
    /// g_qn_desc, one HLS stream per url_info (CDN line) at the
    /// server's actual current_qn. Testable without the network.
    static func streams(fromPlayInfo playurl: JSONValue) -> [PlayStream] {
        var qualityNames = Self.qualityNames
        for entry in playurl["g_qn_desc"].arrayValue {
            if let qn = entry["qn"].intValue, let desc = entry["desc"].stringValue {
                qualityNames[qn] = desc
            }
        }
        var streams: [PlayStream] = []
        for stream in playurl["stream"].arrayValue {
            // Only HLS: AVPlayer cannot play FLV.
            guard stream["protocol_name"].stringValue == "http_hls" else { continue }
            for format in stream["format"].arrayValue {
                guard format["format_name"].stringValue == "ts"
                        || format["format_name"].stringValue == "fmp4" else { continue }
                for codec in format["codec"].arrayValue {
                    guard codec["codec_name"].stringValue == "avc" else { continue }
                    // The server's actual quality for anonymous requests.
                    let qn = codec["current_qn"].intValue ?? 0
                    let quality = qualityNames[qn] ?? "原画"
                    guard let baseURL = codec["base_url"].stringValue, !baseURL.isEmpty else { continue }
                    for urlInfo in codec["url_info"].arrayValue {
                        guard let host = urlInfo["host"].stringValue, !host.isEmpty else { continue }
                        let extra = urlInfo["extra"].stringValue ?? ""
                        let full = host + baseURL + extra
                        guard let streamURL = URL(string: full) else { continue }
                        streams.append(PlayStream(
                            url: streamURL,
                            quality: quality,
                            line: Self.lineName(from: host)
                        ))
                    }
                }
            }
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
                var host = BilibiliDanmaku.defaultHost
                var token = ""
                // Best effort: the token endpoint is risk-controlled
                // from some networks (-352); fall back to the default
                // host with an empty token, which still receives.
                if let json = try? await http.getJSON(
                    "\(Self.apiBase)/xlive/web-room/v1/index/getDanmuInfo?id=\(roomID)&type=0",
                    headers: ["Referer": "https://live.bilibili.com/\(roomID)"]
                ), json["code"].intValue == 0 {
                    token = json["data"]["token"].stringValue ?? ""
                    if let firstHost = json["data"]["host_list"][0]["host"].stringValue, !firstHost.isEmpty {
                        host = firstHost
                    }
                }
                #if !os(Linux)
                for await item in BilibiliDanmaku.stream(roomID: roomID, token: token, host: host) {
                    continuation.yield(item)
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Mapping helpers

    /// Pure parser for a list item (recommend / category / search).
    /// Testable without the network.
    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let roomID = item["roomid"].stringValue ?? ""
        return LiveRoom(
            id: "bili-\(roomID)",
            platform: .bilibili,
            roomID: roomID,
            title: item["title"].stringValue ?? "",
            anchorName: item["uname"].stringValue ?? "",
            anchorAvatarURL: httpURL(item["face"].stringValue),
            coverURL: httpURL(HaoText.firstNonEmpty(item["cover"].stringValue, item["user_cover"].stringValue)),
            categoryName: item["area_name"].stringValue,
            viewerCount: item["online"].intValue ?? 0,
            // The list endpoints only return live rooms, and the
            // items carry no live_status field: missing means live.
            isLive: item["live_status"].intValue != 0
        )
    }

    /// "//i0.hdslb.com/..." -> https URL; nil for empty strings.
    private static func httpURL(_ string: String?) -> URL? {
        guard var s = string, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// "https://d1--ov-gotcha05.bilivideo.com" -> "gotcha05".
    private static func lineName(from host: String) -> String {
        var name = host
        if let schemeRange = name.range(of: "://") {
            name = String(name[schemeRange.upperBound...])
        }
        name = name.split(separator: ".").first.map(String.init) ?? name
        if let dashRange = name.range(of: "--") {
            name = String(name[dashRange.upperBound...])
        }
        if name.hasPrefix("ov-") { name = String(name.dropFirst(3)) }
        return name.isEmpty ? host : name
    }
}
