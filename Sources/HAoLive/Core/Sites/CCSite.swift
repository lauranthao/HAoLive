// CCSite.swift
// HAo Live — real NetEase CC adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   recommend  GET cc.163.com/api/category/live/?format=json&start=0&size=3
//              -> {lives: [{cuteid, title, cover, nickname, purl,
//                  gamename, status (1 = live), vision_visitor,
//                  webcc_visitor/hot_score (heat), m3u8,
//                  stream_list: {high/medium/low/original:
//                    {vbr, CDN_FMT: {hs/ali/fws: query suffix}}} }]}
//              (3 rooms; the list item already carries m3u8 +
//              stream_list, so playURLs can use the carried payload)
//   categories GET inf.ds.163.com/v1/web/game-center/basic/base-info-list/by-type?gameType=NETEASE
//              -> {code: 200, result: [{appKey, name, icon}]} (107 games)
//              + POST inf-act.ds.163.com/v1/act-web/pageConf/commonAppConfig
//              {"id": "67b32cdd1801fc391a6c2657"} (public page-config id,
//              not a credential) -> {code: 200, result: {itemList:
//              [{name: "直播入口列表", itemList: [{name (game appKey),
//              content: "https://cc.163.com/n/ds_category/{id}/" or
//              "https://cc.163.com/{roomId}/"}]}]}} (24 entries)
//   category   GET cc.163.com/api/category/{gameId}/?format=json&tag_id=0&start=&size=
//   search     GET cc.163.com/search/anchor/?query=&size=&page=
//              (trailing slash: the bare path 301s to it)
//              -> {webcc_anchor: {result: [{cuteid, title, portrait,
//                  nickname, gamename, status, follower_num}]}}
//              NOTE: VM could not verify this endpoint — the bare path
//              301s, and the slashed path timed out from this VM
//              (egress slowness). Implemented per Pure Live; needs a
//              device check.
//   detail     GET api.cc.163.com/v1/activitylives/anchor/lives?anchor_ccid={cuteid}
//              -> {data: {"{cuteid}": {channel_id}}} (verified)
//              GET cc.163.com/live/channel/?channelids={channelId}
//              -> {data: [{ccid, title, nickname, gamename, status,
//                  cover, purl, m3u8, stream_list, follower_num}]}
//              (verified; the room used was a replay, status 1)
//   play URLs: per tier, each CDN_FMT value is a query suffix
//              appended to the m3u8 base (base already carries
//              ?secret=..., so the suffix joins with &). Signed
//              suffixes are used verbatim, never re-signed.
// Danmaku: none (Pure Live's EmptyDanmaku) — default empty impl.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CCSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .cc
    private let http = HTTPClient.shared

    private static let webBase = "https://cc.163.com"
    private static let pageSize = 30

    /// Quality tier -> display label. (Pure Live's reflect map.)
    private static let qualityLabels: [String: String] = [
        "blueray": "原画", "original": "原画",
        "ultra": "蓝光",
        "high": "高清",
        "medium": "标准", "standard": "标准",
        "low": "低清",
    ]

    /// CDN line order: preferred lines first (Pure Live's priority).
    private static let preferredLines = ["hs", "ks", "ali", "fws", "wy"]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let gamesJSON = try await http.getJSON(
            "https://inf.ds.163.com/v1/web/game-center/basic/base-info-list/by-type?gameType=NETEASE",
            headers: ["Referer": "https://ds.163.com/glive/", "Origin": "https://ds.163.com"]
        )
        let configJSON = try await http.postJSONParsed(
            "https://inf-act.ds.163.com/v1/act-web/pageConf/commonAppConfig",
            jsonData: Self.configRequestBody(),
            headers: ["Referer": "https://ds.163.com/glive/", "Origin": "https://ds.163.com"]
        )
        return Self.categories(games: gamesJSON, config: configJSON)
    }

    /// Pure parser for the games + live-entry config pair.
    /// Testable without the network.
    static func categories(games: JSONValue, config: JSONValue) -> [LiveCategory] {
        guard games["code"].intValue == 200, config["code"].intValue == 200 else { return [] }
        var metadata: [String: JSONValue] = [:]
        for row in games["result"].arrayValue {
            guard let key = row["appKey"].stringValue, !key.isEmpty else { continue }
            metadata[key] = row
        }
        var out: [LiveCategory] = []
        var seen: Set<String> = []
        for group in config["result"]["itemList"].arrayValue {
            guard group["name"].stringValue == "直播入口列表" else { continue }
            for entry in group["itemList"].arrayValue {
                guard entry["hidden"].boolValue != true,
                      let name = entry["name"].stringValue, !name.isEmpty,
                      let content = entry["content"].stringValue,
                      let game = metadata[name],
                      let gameName = game["name"].stringValue, !gameName.isEmpty,
                      let url = URL(string: content),
                      url.host == "cc.163.com" else { continue }
                let path = url.path
                if let categoryID = Self.categoryID(fromPath: path) {
                    let id = "cc-\(categoryID)"
                    guard seen.insert(id).inserted else { continue }
                    out.append(LiveCategory(id: id, platform: .cc, name: gameName, iconName: nil, iconURL: Self.imageURL(game["icon"].stringValue)))
                } else if let roomID = Self.officialRoomID(fromPath: path) {
                    let id = "cc-official-\(roomID)"
                    guard seen.insert(id).inserted else { continue }
                    out.append(LiveCategory(id: id, platform: .cc, name: gameName, iconName: nil, iconURL: Self.imageURL(game["icon"].stringValue)))
                }
            }
        }
        return out
    }

    /// "/n/ds_category/123/" -> "123".
    static func categoryID(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "n", parts[1] == "ds_category",
              parts[2].allSatisfy(\.isNumber) else { return nil }
        return parts[2]
    }

    /// "/123456/" -> "123456" (an official room entry).
    static func officialRoomID(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 1, parts[0].allSatisfy(\.isNumber) else { return nil }
        return parts[0]
    }

    /// The public page-config id for CC's live-entry list (Pure Live's
    /// CCCatalog.configurationId). An identifier of a public page, not
    /// a credential, key or secret.
    static func configRequestBody() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": "67b32cdd1801fc391a6c2657"], options: [])) ?? Data()
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await liveList(start: 0, size: Self.pageSize)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        return try await liveList(start: (page - 1) * Self.pageSize, size: Self.pageSize)
    }

    private func liveList(start: Int, size: Int) async throws -> [LiveRoom] {
        let json = try await http.getJSON("\(Self.webBase)/api/category/live/?format=json&start=\(start)&size=\(size)")
        return json["lives"].arrayValue.map(Self.room(fromListItem:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        if category.id.hasPrefix("cc-official-") {
            let roomID = String(category.id.dropFirst("cc-official-".count))
            let room = try await roomDetail(roomID: roomID)
            return room.isLive ? [room] : []
        }
        guard category.id.hasPrefix("cc-"),
              let gameID = Int(category.id.dropFirst("cc-".count)) else { return [] }
        let start = (page - 1) * Self.pageSize
        let json = try await http.getJSON("\(Self.webBase)/api/category/\(gameID)/?format=json&tag_id=0&start=\(start)&size=\(Self.pageSize)")
        return json["lives"].arrayValue.map(Self.room(fromListItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let json = try await http.getJSON("\(Self.webBase)/search/anchor/?query=\(encoded)&size=\(Self.pageSize)&page=\(page)")
        return json["webcc_anchor"]["result"].arrayValue.map(Self.room(fromSearchItem:))
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let channelID = try await channelID(forAnchor: roomID)
        let json = try await http.getJSON("\(Self.webBase)/live/channel/?channelids=\(channelID)")
        guard !json["data"][0].isNull else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return Self.room(fromChannelData: json["data"][0], fallbackID: roomID)
    }

    /// Step 1 of detail: anchor ccid -> channel_id.
    private func channelID(forAnchor anchorID: String) async throws -> String {
        let json = try await http.getJSON("https://api.cc.163.com/v1/activitylives/anchor/lives?anchor_ccid=\(anchorID)")
        if let id = json["data"][anchorID]["channel_id"].stringValue, !id.isEmpty { return id }
        if let id = json["data"][0]["channel_id"].stringValue, !id.isEmpty { return id }
        throw LiveSiteError.roomNotFound(anchorID)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        if let carried = room.playDataJSON,
           let data = carried.data(using: .utf8),
           let json = JSONValue.parse(data) {
            let streams = Self.streams(fromChannelData: json, roomID: room.roomID)
            if !streams.isEmpty { return streams }
        }
        let fresh = try await roomDetail(roomID: room.roomID)
        guard let carried = fresh.playDataJSON,
              let data = carried.data(using: .utf8),
              let json = JSONValue.parse(data) else { return [] }
        return Self.streams(fromChannelData: json, roomID: room.roomID)
    }

    /// Pure builder for a channel object (list item or detail object):
    /// every tier x every CDN line, best first. The tier map is
    /// `stream_list` (live) or `quickplay`; `resolution` (recorded
    /// video) replaces the tier map when present, as in Pure Live.
    /// Testable without the network.
    static func streams(fromChannelData data: JSONValue, roomID: String) -> [PlayStream] {
        let qualityData: JSONValue
        if !data["resolution"].isNull, !data["resolution"].objectValue.isEmpty {
            qualityData = data["resolution"]
        } else if !data["quickplay"].isNull, !data["quickplay"].objectValue.isEmpty {
            qualityData = data["quickplay"]
        } else {
            qualityData = data["stream_list"]
        }
        guard !qualityData.isNull else { return [] }
        let base = data["m3u8"].stringValue ?? data["link"].stringValue ?? ""
        let headers = PlaybackHeaders.headers(platform: .cc, roomID: roomID)
        var tiers: [(key: String, label: String, rank: Int, lines: [(name: String, url: String)])] = []
        for (key, value) in Self.tierEntries(qualityData) {
            let cdn = value["CDN_FMT"].isNull ? value["cdn"] : value["CDN_FMT"]
            guard !cdn.isNull else { continue }
            var lines: [(name: String, url: String)] = []
            for line in Self.orderedCDNLines(cdn) {
                guard let url = Self.resolveLiveCdnURL(base: base, lineValue: line.value),
                      !url.isEmpty else { continue }
                lines.append((name: line.name, url: url))
            }
            guard !lines.isEmpty else { continue }
            let vbr = value["vbr"].intValue ?? 0
            tiers.append((key: key, label: qualityLabels[key.lowercased()] ?? key, rank: Self.qualityRank(key, vbr: vbr), lines: lines))
        }
        tiers.sort { $0.rank > $1.rank }
        var streams: [PlayStream] = []
        for tier in tiers {
            for line in tier.lines {
                guard let url = URL(string: line.url) else { continue }
                streams.append(PlayStream(url: url, quality: tier.label, line: line.name, headers: headers))
            }
        }
        return streams
    }

    /// Tier entries of a quality map (object form) or a quality list
    /// (array form, each element carrying its tier name).
    static func tierEntries(_ qualityData: JSONValue) -> [(key: String, value: JSONValue)] {
        if !qualityData.objectValue.isEmpty {
            return qualityData.objectValue.map { (key: $0.key, value: $0.value) }
        }
        var out: [(key: String, value: JSONValue)] = []
        for item in qualityData.arrayValue {
            let key = item["quality"].stringValue ?? item["name"].stringValue ?? item["key"].stringValue ?? ""
            guard !key.isEmpty else { continue }
            out.append((key: key, value: item))
        }
        return out
    }

    /// CDN lines in Pure Live's order: preferred lines first, then
    /// the rest alphabetically (JSONValue does not preserve key
    /// order, so the remainder is sorted for stability).
    static func orderedCDNLines(_ cdn: JSONValue) -> [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        var rest: [(name: String, value: String)] = []
        for (name, value) in cdn.objectValue {
            guard let text = value.stringValue else { continue }
            if preferredLines.contains(name.lowercased()) {
                out.append((name: name, value: text))
            } else {
                rest.append((name: name, value: text))
            }
        }
        out.sort { preferredLines.firstIndex(of: $0.name.lowercased()) ?? 99 < preferredLines.firstIndex(of: $1.name.lowercased()) ?? 99 }
        rest.sort { $0.name < $1.name }
        return out + rest
    }

    /// Pure Live's _resolveLiveCdnUrl: a // value is https, a full
    /// URL is used as-is, an empty value falls back to the base, and
    /// anything else is a query suffix joined onto the base
    /// (the base already carries ?secret=..., so the join is &).
    static func resolveLiveCdnURL(base: String, lineValue: String) -> String? {
        let value = lineValue.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("//") { return "https:" + value }
        if let url = URL(string: value), url.scheme != nil {
            return (url.scheme == "http" || url.scheme == "https") ? value : nil
        }
        if value.isEmpty { return base.isEmpty ? nil : base }
        guard !base.isEmpty else { return nil }
        let suffix = value.replacingOccurrences(of: #"^[?&]+"#, with: "", options: .regularExpression)
        return base + (base.contains("?") ? "&" : "?") + suffix
    }

    /// Tier rank: named tier first (原画 6, 蓝光 5, 高清 4,
    /// 标准 3, 低清 2), bitrate breaks ties inside a tier.
    static func qualityRank(_ key: String, vbr: Int) -> Int {
        let normalized = key.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
        let tier: Int
        switch normalized {
        case "blueray", "original", "origin", "source": tier = 6
        case "ultra": tier = 5
        case "high", "hd": tier = 4
        case "medium", "standard", "sd": tier = 3
        case "low", "ld": tier = 2
        default: tier = 0
        }
        if tier == 0 { return vbr }
        return tier * 1_000_000 + min(max(vbr, 0), 999_999)
    }

    // MARK: - Mapping helpers

    /// Audience: `webcc_visitor` / `hot_score` / `visitor` is the
    /// platform heat (large), `vision_visitor` / `online_num` is the
    /// actual concurrent audience. viewerCount uses the online
    /// number when present, heat otherwise.
    static func viewerCount(of item: JSONValue) -> Int {
        if let online = item["vision_visitor"].intValue, online > 0 { return online }
        if let online = item["online_num"].intValue, online > 0 { return online }
        return item["webcc_visitor"].intValue ?? item["hot_score"].intValue ?? item["visitor"].intValue ?? 0
    }

    /// Pure parser for a list / category / detail item. The whole
    /// item JSON rides on playDataJSON so playURLs can use the
    /// carried m3u8 + stream_list without re-fetching.
    /// Testable without the network.
    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let roomID = item["cuteid"].stringValue ?? item["ccid"].stringValue ?? ""
        return LiveRoom(
            id: "cc-\(roomID)",
            platform: .cc,
            roomID: roomID,
            title: item["title"].stringValue ?? "",
            anchorName: item["nickname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(item["purl"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(item["cover"].stringValue, item["poster"].stringValue)),
            categoryName: HaoText.firstNonEmpty(item["gamename"].stringValue, item["game_name"].stringValue),
            viewerCount: viewerCount(of: item),
            isLive: item["status"].intValue.map { $0 == 1 } ?? true,
            playDataJSON: item.jsonString
        )
    }

    static func room(fromChannelData data: JSONValue, fallbackID: String) -> LiveRoom {
        let roomID = data["ccid"].stringValue ?? data["cuteid"].stringValue ?? fallbackID
        return LiveRoom(
            id: "cc-\(roomID)",
            platform: .cc,
            roomID: roomID,
            title: data["title"].stringValue ?? "",
            anchorName: data["nickname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(data["purl"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(data["cover"].stringValue, data["poster"].stringValue)),
            categoryName: HaoText.firstNonEmpty(data["gamename"].stringValue, data["game_name"].stringValue),
            viewerCount: viewerCount(of: data),
            isLive: data["status"].intValue.map { $0 == 1 } ?? false,
            playDataJSON: data.jsonString
        )
    }

    static func room(fromSearchItem item: JSONValue) -> LiveRoom {
        let roomID = item["cuteid"].stringValue ?? ""
        return LiveRoom(
            id: "cc-\(roomID)",
            platform: .cc,
            roomID: roomID,
            title: item["title"].stringValue ?? "",
            anchorName: item["nickname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(item["portrait"].stringValue),
            coverURL: Self.imageURL(item["portrait"].stringValue),
            categoryName: HaoText.firstNonEmpty(item["gamename"].stringValue, item["game_name"].stringValue),
            viewerCount: item["follower_num"].intValue ?? 0,
            isLive: item["status"].intValue.map { $0 == 1 } ?? false
        )
    }
}
