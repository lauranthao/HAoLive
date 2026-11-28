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
//             The API lists FLV URLs only (h264+aac, ffprobe-verified
//             2026-11-27); they are used verbatim — mpv plays FLV
//             natively. The old .flv→.m3u8 derivation was WRONG: the
//             swapped URL returns HTTP 200 with FLV bytes, not a
//             playlist (verified live 2026-11-27).
//   room page GET https://live.kuaishou.com/u/{userId} — the page
//             embeds window.__INITIAL_STATE__ (plain JSON) with:
//               liveroom: {websocketUrls: [], token: "", playList: [{
//                 liveStream: {...}, author: {...}, gameInfo: {...},
//                 isLiving: Bool, errorType: {type, title, content, url}}]}
//             Still rate-limited from this VM ("请求过快，请稍后重试"),
//             and a live room's own page carries an EMPTY liveStream
//             (verified 2026-11-27), so the room-page path is only a
//             fallback; the list payload (LiveRoom.playDataJSON) is
//             the verified source of streams.
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
            let iconString = item["icon"].stringValue ?? item["iconUrl"].stringValue ?? item["pic"].stringValue ?? item["imgUrl"].stringValue ?? ""
            return LiveCategory(id: "kuaishou-\(id)", platform: .kuaishou, name: name, iconName: nil, iconURL: Self.imageURL(iconString))
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
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let gameID = category.id.dropFirst("kuaishou-".count)
        // Pure Live: short ids are game boards, long ids are non-game boards.
        let api = gameID.count < 7 ? "gameboard/list" : "non-gameboard/list"
        let url = "\(Self.webBase)/live_api/\(api)?filterType=0&pageSize=20&gameId=\(gameID)&page=\(page)"
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

    // MARK: - Play URLs (Pure Live's Kuaishou route, ported)
    //
    // The play URLs ride the LIST item (home/list liveInfo.playUrls
    // / board list playUrls) — Pure Live's getPlayUrls returns the
    // quality.data lists built from liveroom.data and never fetches
    // a room page for playback. The room page (live.kuaishou.com/u/)
    // is rate-limited and, when it answers at all, its playList
    // entry carries an EMPTY liveStream (verified live 2026-11-27:
    // a room live on home/list had liveStream keys [] on its own
    // page) — the old playURLs(roomID:) path returned [] for it.
    // The list payload is carried on LiveRoom.playDataJSON.
    // URLs are used VERBATIM: they are FLV (h264+aac, ffprobe-verified
    // 2026-11-27) and mpv plays FLV natively. The old .flv→.m3u8
    // derivation is WRONG for this CDN: the swapped URL returns
    // HTTP 200 with FLV bytes, not a playlist (verified live
    // 2026-11-27: 2.8 MB response starting "FLV\x01\x05"), so
    // AVPlayer failed to parse it as HLS. Derivation removed.

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let headers = PlaybackHeaders.headers(platform: .kuaishou, roomID: room.roomID)
        if let playData = room.playDataJSON,
           let data = playData.data(using: .utf8),
           let playUrls = JSONValue.parse(data) {
            let streams = Self.streams(fromPlayUrls: playUrls, headers: headers)
            if !streams.isEmpty { return streams }
        }
        // Fallback: room page (rate-limited; often an empty liveStream).
        guard let entry = try? await liveEntry(userID: room.roomID) else { return [] }
        let liveStream = entry["liveStream"]
        guard !liveStream.isNull else { return [] }
        return Self.streams(fromLiveStream: liveStream, headers: headers)
    }

    /// Pure parser for a playUrls value (Pure Live's
    /// parsePlayQualities): h264 first, hevc second, direct
    /// adaptationSet descriptors as fallback; same-quality URLs
    /// across CDN lines are merged and deduped; URLs verbatim.
    /// Testable without the network.
    static func streams(fromPlayUrls playUrls: JSONValue, headers: [String: String] = [:]) -> [PlayStream] {
        // playUrls is a list of descriptors; a single {h264/hevc}
        // map is also accepted.
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
                guard let url = URL(string: urlString) else { continue }
                streams.append(PlayStream(
                    url: url,
                    quality: entry.name,
                    line: index == 0 ? "主线路" : "线路\(index + 1)",
                    headers: headers
                ))
            }
        }
        // Legacy shape: playUrls: [{url, quality, type}] and/or
        // hlsPlayUrl / playUrl string fields.
        if streams.isEmpty {
            streams.append(contentsOf: legacyStreams(fromPlayUrls: playUrls, headers: headers))
        }
        return streams
    }

    /// Room-page shape: liveStream.playUrls.
    static func streams(fromLiveStream liveStream: JSONValue, headers: [String: String] = [:]) -> [PlayStream] {
        let streams = Self.streams(fromPlayUrls: liveStream["playUrls"], headers: headers)
        if !streams.isEmpty { return streams }
        return legacyStreams(fromLiveStream: liveStream, headers: headers)
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

    /// Legacy playUrls shape fallback (verbatim URLs).
    /// Testable without the network.
    static func legacyStreams(fromPlayUrls playUrls: JSONValue, headers: [String: String] = [:]) -> [PlayStream] {
        var streams: [PlayStream] = []
        for item in playUrls.arrayValue {
            guard let urlString = item["url"].stringValue,
                  let url = URL(string: urlString) else { continue }
            streams.append(PlayStream(
                url: url,
                quality: item["quality"].stringValue ?? "自适应",
                line: "主线路",
                headers: headers
            ))
        }
        return streams
    }

    /// Room-page legacy shape: liveStream.playUrls /
    /// hlsPlayUrl / playUrl fields (verbatim URLs).
    static func legacyStreams(fromLiveStream liveStream: JSONValue, headers: [String: String] = [:]) -> [PlayStream] {
        var streams = legacyStreams(fromPlayUrls: liveStream["playUrls"], headers: headers)
        for key in ["hlsPlayUrl", "playUrl"] {
            if let urlString = liveStream[key].stringValue,
               let url = URL(string: urlString) {
                streams.append(PlayStream(url: url, quality: "自适应", line: "主线路", headers: headers))
            }
        }
        return streams
    }

    // MARK: - Danmaku

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
            anchorAvatarURL: Self.imageURL(HaoText.firstNonEmpty(author["avatar"].stringValue, author["avatarUrl"].stringValue)),
            coverURL: Self.imageURL(entry["cover"].stringValue),
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
            anchorAvatarURL: Self.imageURL(author["avatar"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(item["poster"].stringValue, gameInfo["poster"].stringValue)),
            categoryName: gameInfo["name"].stringValue,
            viewerCount: item["watchingCount"].intValue ?? 0,
            isLive: true,
            playDataJSON: item["playUrls"].jsonString
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
            anchorAvatarURL: Self.imageURL(author["avatar"].stringValue),
            coverURL: Self.imageURL(item["poster"].stringValue),
            categoryName: gameInfo["name"].stringValue,
            viewerCount: item["watchingCount"].intValue ?? 0,
            isLive: true,
            playDataJSON: item["playUrls"].jsonString
        )
    }

}
