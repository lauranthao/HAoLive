// KuaishouSite.swift
// HAo Live — real Kuaishou adapter (anonymous, no login).
// Pure Live's route, verified live from this VM 2026-11-27:
//   recommend GET live.kuaishou.com/live_api/home/list
//             -> data.list[].gameLiveInfo[].liveInfo[]
//             (author, gameInfo, watchingCount, playUrls)
//   category  GET live.kuaishou.com/live_api/gameboard/list
//             (short game ids) or /live_api/non-gameboard/list
//             (long ids) ?filterType=0&pageSize=20&gameId=&page=
//             -> data.list[] (author, caption, poster, playUrls)
//   playUrls descriptors: {h264: {adaptationSet: {representation:
//             [{url, level, bitrate, name, shortName, qualityType}]}}}
//             or {hevc: ...} or a direct adaptationSet descriptor.
//             The API lists FLV URLs only (139/139 in the live probe).
//             Kuaishou's CDN serves the same signed stream as HLS at
//             the same path with a .m3u8 suffix — verified live: the
//             swapped URL returns a valid #EXTM3U master playlist, so
//             AVPlayer can play it. The adapter derives the HLS URL
//             from every FLV URL instead of dropping it.
//   room page GET https://live.kuaishou.com/u/{userId} — the page
//             embeds window.__INITIAL_STATE__ (plain JSON) with:
//               liveroom: {websocketUrls: [], token: "", playList: [{
//                 liveStream: {...}, author: {...}, gameInfo: {...},
//                 isLiving: Bool, errorType: {type, title, content, url}}]}
//             Still rate-limited from this VM ("请求过快，请稍后重试"),
//             so the room-page path is defensive; the list APIs above
//             are the verified source of rooms and streams.
// Danmaku: live WebSocket feed (KuaiShouPack protobuf). Room info
// comes from m.gifshow.com/fw/live/{userId} (wsFeedInfo:
// liveStreamId, websocketUrls[0], token); enter with CS_ENTER_ROOM,
// heartbeat CS_HEARTBEAT every 20s, chat is SC_FEED_PUSH (310) →
// commentFeeds. Implemented from the wbt5/real-url reference
// handler; NOT yet verified against Kuaishou's live server from
// this VM (Kuaishou rate-limits this egress IP). Needs a domestic
// real-device check.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class KuaishouSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .kuaishou
    private let http = HTTPClient.shared

    private static let webBase = "https://live.kuaishou.com"

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let state = try await initialState(path: "")
        return Self.categories(fromCategoryList: state["category"]["simpleCategoryList"])
    }

    /// Pure parser for simpleCategoryList. Testable without the network.
    static func categories(fromCategoryList list: JSONValue) -> [LiveCategory] {
        let items = list["hotCategoryList"].arrayValue + list["recommendCategoryList"].arrayValue
        var seen = Set<String>()
        return items.compactMap { item in
            guard let id = item["id"].stringValue ?? item["categoryId"].stringValue,
                  let name = item["name"].stringValue ?? item["categoryName"].stringValue ?? item["title"].stringValue,
                  !name.isEmpty, seen.insert(id).inserted else { return nil }
            return LiveCategory(id: "kuaishou-\(id)", platform: .kuaishou, name: name, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        let json = try await http.getJSON("\(Self.webBase)/live_api/home/list")
        var rooms: [LiveRoom] = []
        for item in json["data"]["list"].arrayValue {
            for game in item["gameLiveInfo"].arrayValue {
                for live in game["liveInfo"].arrayValue {
                    if let room = Self.room(fromHomeItem: live) { rooms.append(room) }
                }
            }
        }
        return rooms
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        let gameID = category.id.dropFirst("kuaishou-".count)
        // Pure Live: short ids are game boards, long ids are non-game boards.
        let api = gameID.count < 7 ? "gameboard/list" : "non-gameboard/list"
        let url = "\(Self.webBase)/live_api/\(api)?filterType=0&pageSize=20&gameId=\(gameID)&page=1"
        let json = try await http.getJSON(url)
        return json["data"]["list"].arrayValue.compactMap(Self.room(fromBoardItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        // No verified search endpoint for Kuaishou live.
        []
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        []
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let entry = try await liveEntry(userID: roomID)
        return Self.room(fromEntry: entry, userID: roomID)
    }

    // MARK: - Play URLs

    func playURLs(roomID: String) async throws -> [PlayStream] {
        let entry = try await liveEntry(userID: roomID)
        let liveStream = entry["liveStream"]
        guard !liveStream.isNull else { return [] }
        return Self.streams(fromLiveStream: liveStream)
    }

    /// Pure parser for the liveStream object (Pure Live's
    /// parsePlayQualities): h264 first, hevc second, direct
    /// adaptationSet descriptors as fallback; same-quality URLs across
    /// CDN lines are merged and deduped. Every URL is converted to its
    /// HLS form (see hlsURL(from:)) — AVPlayer cannot play FLV.
    /// Testable without the network.
    static func streams(fromLiveStream liveStream: JSONValue) -> [PlayStream] {
        let playUrls = liveStream["playUrls"]
        // playUrls is a list of descriptors; a single {h264/hevc} map
        // is also accepted.
        let descriptors = playUrls.arrayValue.isEmpty && !playUrls.isNull ? [playUrls] : playUrls.arrayValue
        var merged: [(name: String, sort: Int, codecRank: Int, urls: [String])] = []
        for descriptor in descriptors {
            guard !descriptor.isNull else { continue }
            // h264/avc first (codecRank 0), hevc/h265 second (" · H.265").
            var sets: [(suffix: String, codecRank: Int, descriptor: JSONValue)] = []
            for codec in ["h264", "avc"] {
                if !representations(of: descriptor[codec]).isEmpty {
                    sets.append((suffix: "", codecRank: 0, descriptor: descriptor[codec]))
                    break
                }
            }
            for codec in ["hevc", "h265"] {
                if !representations(of: descriptor[codec]).isEmpty {
                    sets.append((suffix: " · H.265", codecRank: 1, descriptor: descriptor[codec]))
                    break
                }
            }
            if sets.isEmpty { sets.append((suffix: "", codecRank: 0, descriptor: descriptor)) }

            for set in sets {
                for item in representations(of: set.descriptor) {
                    guard let urlString = item["url"].stringValue, !urlString.isEmpty,
                          urlString.hasPrefix("http") else { continue }
                    let sort = item["level"].intValue ?? item["bitrate"].intValue ?? 0
                    let rawName = HaoText.firstNonEmpty(
                        item["name"].stringValue,
                        item["shortName"].stringValue,
                        item["qualityType"].stringValue
                    ) ?? "清晰度 \(sort)"
                    let name = set.suffix.isEmpty ? rawName : rawName + set.suffix
                    if let index = merged.firstIndex(where: { $0.name == name && $0.sort == sort && $0.codecRank == set.codecRank }) {
                        if !merged[index].urls.contains(urlString) { merged[index].urls.append(urlString) }
                    } else {
                        merged.append((name: name, sort: sort, codecRank: set.codecRank, urls: [urlString]))
                    }
                }
            }
        }
        // Best codec first, then highest level/bitrate first.
        merged.sort { a, b in
            if a.codecRank != b.codecRank { return a.codecRank < b.codecRank }
            return a.sort > b.sort
        }
        var streams: [PlayStream] = []
        for entry in merged {
            // One stream per CDN line; the first line is the default.
            for (index, urlString) in entry.urls.enumerated() {
                guard let url = hlsURL(from: urlString) else { continue }
                streams.append(PlayStream(
                    url: url,
                    quality: entry.name,
                    line: index == 0 ? "主线路" : "线路\(index + 1)"
                ))
            }
        }
        // Legacy shape: playUrls: [{url, quality, type}] and/or
        // hlsPlayUrl / playUrl string fields.
        if streams.isEmpty {
            streams.append(contentsOf: legacyStreams(fromLiveStream: liveStream))
        }
        return streams
    }

    /// The representation list of one descriptor: descriptor
    /// .adaptationSet.representation, or descriptor.representation.
    static func representations(of descriptor: JSONValue) -> [JSONValue] {
        guard !descriptor.isNull else { return [] }
        let adaptationSet = descriptor["adaptationSet"]
        if !adaptationSet.isNull {
            return adaptationSet["representation"].arrayValue
        }
        return descriptor["representation"].arrayValue
    }

    /// Kuaishou's CDN serves the same signed stream as HLS at the same
    /// path with a .m3u8 suffix (verified live 2026-11-27: the swapped
    /// URL returns a valid #EXTM3U master playlist). HLS URLs pass
    /// through; FLV URLs are swapped; anything else is dropped.
    static func hlsURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        if urlString.contains(".m3u8") { return url }
        guard urlString.contains(".flv"),
              let range = urlString.range(of: ".flv", options: .backwards) else { return nil }
        var swapped = urlString
        swapped.replaceSubrange(range, with: ".m3u8")
        return URL(string: swapped)
    }

    /// Legacy playUrls shape fallback. Testable without the network.
    static func legacyStreams(fromLiveStream liveStream: JSONValue) -> [PlayStream] {
        var streams: [PlayStream] = []
        for item in liveStream["playUrls"].arrayValue {
            guard let urlString = item["url"].stringValue,
                  let url = hlsURL(from: urlString) else { continue }
            streams.append(PlayStream(
                url: url,
                quality: item["quality"].stringValue ?? "自适应",
                line: "主线路"
            ))
        }
        for key in ["hlsPlayUrl", "playUrl"] {
            if let urlString = liveStream[key].stringValue,
               let url = hlsURL(from: urlString) {
                streams.append(PlayStream(url: url, quality: "自适应", line: "主线路"))
            }
        }
        return streams
    }

    // MARK: - Danmaku

    func sampleDanmaku(roomID: String) async -> [DanmakuItem] {
        [] // no live channel yet; never show fake lines as live danmaku
    }

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return KuaishouDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Page helpers

    /// window.__INITIAL_STATE__ JSON from a live.kuaishou.com page.
    private func initialState(path: String) async throws -> JSONValue {
        let data = try await http.get("\(Self.webBase)/\(path)")
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        guard let state = Self.initialState(fromHTML: html) else {
            throw LiveSiteError.invalidResponse
        }
        return state
    }

    /// Pure parser for window.__INITIAL_STATE__ in page HTML.
    /// Testable without the network.
    static func initialState(fromHTML html: String) -> JSONValue? {
        guard let markerRange = html.range(of: "window.__INITIAL_STATE__=") else { return nil }
        guard let openIndex = html[markerRange.upperBound...].firstIndex(of: "{"),
              let text = HaoText.extractJSONObject(html, from: openIndex),
              let jsonData = text.data(using: .utf8),
              let json = JSONValue.parse(jsonData) else { return nil }
        return json
    }

    /// The first playList entry for a user page. Throws the platform's
    /// own error text when the page reports one (e.g. rate limited).
    private func liveEntry(userID: String) async throws -> JSONValue {
        let state = try await initialState(path: "u/\(userID)")
        let entry = state["liveroom"]["playList"][0]
        guard !entry.isNull else { throw LiveSiteError.roomNotFound(userID) }
        if let title = entry["errorType"]["title"].stringValue, !title.isEmpty {
            throw LiveSiteError.message(title)
        }
        return entry
    }

    // MARK: - Mapping helpers

    /// Pure parser for a playList entry. Testable without the network.
    static func room(fromEntry entry: JSONValue, userID: String) -> LiveRoom {
        let author = entry["author"]
        let gameInfo = entry["gameInfo"]
        return LiveRoom(
            id: "kuaishou-\(userID)",
            platform: .kuaishou,
            roomID: userID,
            title: HaoText.firstNonEmpty(entry["title"].stringValue, gameInfo["name"].stringValue) ?? "",
            anchorName: HaoText.firstNonEmpty(author["userName"].stringValue, author["nickname"].stringValue, author["name"].stringValue) ?? "",
            anchorAvatarURL: URL(string: HaoText.firstNonEmpty(author["avatar"].stringValue, author["avatarUrl"].stringValue) ?? ""),
            coverURL: URL(string: entry["cover"].stringValue ?? ""),
            categoryName: gameInfo["name"].stringValue ?? gameInfo["gameName"].stringValue,
            viewerCount: entry["onlineCount"].intValue ?? entry["watchCount"].intValue ?? 0,
            isLive: entry["isLiving"].boolValue == true
        )
    }

    /// Pure parser for a home/list liveInfo item. The room's own
    /// live screenshot (item.poster) is the cover and the caption is
    /// the title; the game poster and the author's bio are the
    /// fallbacks. (Pure Live uses the game poster + bio; the live
    /// payload's own fields are the better cover and title.)
    /// Testable without the network.
    static func room(fromHomeItem item: JSONValue) -> LiveRoom? {
        let author = item["author"]
        let gameInfo = item["gameInfo"]
        guard let userID = author["id"].stringValue, !userID.isEmpty else { return nil }
        let title = HaoText.firstNonEmpty(
            item["caption"].stringValue,
            (author["description"].stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
        ) ?? ""
        return LiveRoom(
            id: "kuaishou-\(userID)",
            platform: .kuaishou,
            roomID: userID,
            title: title,
            anchorName: author["name"].stringValue ?? "",
            anchorAvatarURL: URL(string: author["avatar"].stringValue ?? ""),
            coverURL: URL(string: HaoText.firstNonEmpty(item["poster"].stringValue, gameInfo["poster"].stringValue) ?? ""),
            categoryName: gameInfo["name"].stringValue,
            viewerCount: item["watchingCount"].intValue ?? 0,
            isLive: true
        )
    }

    /// Pure parser for a gameboard / non-gameboard list item.
    /// Testable without the network.
    static func room(fromBoardItem item: JSONValue) -> LiveRoom? {
        let author = item["author"]
        let gameInfo = item["gameInfo"]
        guard let userID = author["id"].stringValue, !userID.isEmpty else { return nil }
        return LiveRoom(
            id: "kuaishou-\(userID)",
            platform: .kuaishou,
            roomID: userID,
            title: item["caption"].stringValue ?? "",
            anchorName: author["name"].stringValue ?? "",
            anchorAvatarURL: URL(string: author["avatar"].stringValue ?? ""),
            coverURL: URL(string: item["poster"].stringValue ?? ""),
            categoryName: gameInfo["name"].stringValue,
            viewerCount: item["watchingCount"].intValue ?? 0,
            isLive: true
        )
    }

}
