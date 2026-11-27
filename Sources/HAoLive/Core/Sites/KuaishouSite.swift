// KuaishouSite.swift
// HAo Live — real Kuaishou adapter (anonymous, no login).
// Verified live from this VM 2026-11-26:
//   room page GET https://live.kuaishou.com/u/{userId} — the page
//   embeds window.__INITIAL_STATE__ (plain JSON) with:
//     liveroom: {websocketUrls: [], token: "", playList: [{
//       liveStream: {...}, author: {...}, gameInfo: {...},
//       isLiving: Bool, errorType: {type, title, content, url}}]}
//   home page GET https://live.kuaishou.com/ — same state object with:
//     home: {homeLiveStream, liveCardList, category}
//     category: {simpleCategoryList: {hotCategoryList,
//       recommendCategoryList}}
// NOT verifiable from this VM: the VM's egress IP is rate-limited
// by Kuaishou ("请求过快，请稍后重试"), so every list and every
// liveStream came back empty. The parsing below is therefore
// defensive across the plausible liveStream shapes and the adapter
// surfaces the platform's own error text when the room page says so.
// Shapes that need a China-network device to confirm:
//   - liveStream.playUrls entries (url + quality + type) and/or
//     hlsPlayUrl / playUrl string fields
//   - liveCardList / category list item keys
//   - any search endpoint (none verified; search returns [] for now)
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
        let state = try await initialState(path: "")
        return state["home"]["liveCardList"].arrayValue.compactMap(Self.room(fromCard:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        // No verified per-category list endpoint; the home list is the
        // only verified source. Return it unfiltered rather than a
        // wrong filtered list.
        try await recommendRooms()
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

    /// Pure parser for the liveStream object, defensive across its
    /// plausible shapes (playUrls array and/or hlsPlayUrl/playUrl
    /// strings). Only HLS/m3u8 URLs are offered: AVPlayer cannot
    /// play FLV. Testable without the network.
    static func streams(fromLiveStream liveStream: JSONValue) -> [PlayStream] {
        var streams: [PlayStream] = []
        // Shape 1: playUrls: [{url, quality, type}]
        for item in liveStream["playUrls"].arrayValue {
            guard let urlString = item["url"].stringValue,
                  let url = URL(string: urlString) else { continue }
            let type = item["type"].stringValue ?? ""
            // AVPlayer cannot play FLV; keep HLS/m3u8 only.
            if type.lowercased() == "flv" { continue }
            if !urlString.contains("m3u8") && !type.lowercased().contains("hls") && !type.isEmpty {
                continue
            }
            streams.append(PlayStream(
                url: url,
                quality: item["quality"].stringValue ?? "自适应",
                line: "主线路"
            ))
        }
        // Shape 2: hlsPlayUrl / playUrl string fields.
        for key in ["hlsPlayUrl", "playUrl"] {
            if let urlString = liveStream[key].stringValue,
               let url = URL(string: urlString),
               urlString.contains("m3u8") {
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

    /// Pure parser for a home live card. Testable without the network.
    static func room(fromCard item: JSONValue) -> LiveRoom? {
        let userID = item["userId"].stringValue ?? item["authorId"].stringValue ?? ""
        guard !userID.isEmpty else { return nil }
        let author = item["author"]
        return LiveRoom(
            id: "kuaishou-\(userID)",
            platform: .kuaishou,
            roomID: userID,
            title: HaoText.firstNonEmpty(item["title"].stringValue, item["caption"].stringValue) ?? "",
            anchorName: HaoText.firstNonEmpty(author["userName"].stringValue, author["nickname"].stringValue, item["userName"].stringValue) ?? "",
            anchorAvatarURL: URL(string: author["avatar"].stringValue ?? ""),
            coverURL: URL(string: HaoText.firstNonEmpty(item["cover"].stringValue, item["poster"].stringValue) ?? ""),
            categoryName: item["gameName"].stringValue,
            viewerCount: item["onlineCount"].intValue ?? item["watchCount"].intValue ?? 0,
            isLive: true
        )
    }
}
