// HuyaSite.swift
// HAo Live — real Huya adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-26:
//   categories  GET www.huya.com/cache.php?m=Game&do=getGameList
//               -> {status: 200, gameList: [{gid, gameFullName,
//                  gameHostName, imgUrl}]} (358 games)
//   live list   GET www.huya.com/cache.php?m=LiveList&do=getLiveListByPage
//               &gameId=0&tagAll=0&page=1
//               -> {status: 200, data: {datas: [{profileRoom (room id),
//                  nick, introduction, screenshot, avatar180,
//                  totalCount (string), gameFullName, gid, uid}]}}
//   room page   GET www.huya.com/{room_id} — the page embeds three
//               plain JSON objects:
//                 TT_ROOM_DATA = {type, state ("ON" = live), isOn,
//                   id, profileRoom, introduction, totalCount,
//                   screenshot, gameFullName, gid, startTime}
//                 TT_PROFILE_INFO = {nick, avatar, fans, profileRoom}
//                 hyPlayerConfig.stream = {data: [{gameLiveInfo,
//                   gameStreamInfoList: [{sCdnType, sStreamName,
//                     sHlsUrl, sHlsUrlSuffix, sHlsAntiCode}]}],
//                   vMultiStreamInfo: [{sDisplayName, iBitRate}]}
//   play URL: HLS = sHlsUrl + "/" + sStreamName + "." + sHlsUrlSuffix
//             + "?" + sHlsAntiCode (scheme upgraded to https for ATS).
//             The m3u8 is a master playlist (the anti-code's fm field
//             lists bitrate variants $0..$3), so AVPlayer adapts
//             quality itself: the offered quality is "自适应" and the
//             picker switches CDN lines.
//   HLS playback itself is NOT verifiable from this VM: the CDN
//   answers 403 to this egress IP (the anti-code is IP-bound).
//   Needs a China-network device to confirm playback.
// Danmaku: live TAF/JCE WebSocket channel (wss://cdnws.api.huya.com).
// Room ids come from m.huya.com/{room} (lYyid, lChannelId,
// lSubChannelId); register with WSUserInfo in a WebSocketCommand,
// heartbeat is a bare UserHeartBeatReq every 30s, chat is
// WSPushMessage uri 1400 → MessageNotice. Verified live from this
// VM 2026-11-27: register answered "注册成功", 151 chat messages
// in 91s from room 485503.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HuyaSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .huya
    private let http = HTTPClient.shared

    private static let webBase = "https://www.huya.com"

    /// CDN code -> readable line name. Unknown codes are shown raw.
    private static let cdnNames: [String: String] = [
        "AL": "阿里云", "TX": "腾讯云", "HW": "华为云",
        "WS": "网宿", "DW": "帝联",
    ]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.webBase)/cache.php?m=Game&do=getGameList")
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        return Self.categories(fromGameList: json["gameList"])
    }

    /// Pure parser for the game list. Testable without the network.
    static func categories(fromGameList data: JSONValue) -> [LiveCategory] {
        data.arrayValue.compactMap { item in
            guard let id = item["gid"].stringValue,
                  let name = item["gameFullName"].stringValue, !name.isEmpty else { return nil }
            return LiveCategory(id: "huya-\(id)", platform: .huya, name: name, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await liveList(gameID: 0)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        let gameID = Int(category.id.dropFirst("huya-".count)) ?? 0
        return try await liveList(gameID: gameID)
    }

    private func liveList(gameID: Int, page: Int = 1) async throws -> [LiveRoom] {
        let url = "\(Self.webBase)/cache.php?m=LiveList&do=getLiveListByPage&gameId=\(gameID)&tagAll=0&page=\(page)"
        let json = try await http.getJSON(url)
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        return json["data"]["datas"].arrayValue.map(Self.room(fromListItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    /// Huya's search API. Unverified from this VM (the response shape
    /// is parsed defensively); needs a device to confirm.
    private func search(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://search.huya.com/api/search?huyaSearchType=live&search=\(encoded)&page=1"
        let json = try await http.getJSON(url, headers: ["Referer": "\(Self.webBase)/"])
        let items: [JSONValue]
        if !json["data"].arrayValue.isEmpty {
            items = json["data"].arrayValue
        } else {
            items = json["data"]["list"].arrayValue
        }
        return items.map(Self.room(fromListItem:))
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let html = try await roomPage(roomID: roomID)
        guard let roomData = Self.extractObject(after: "TT_ROOM_DATA", in: html) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let profile = Self.extractObject(after: "TT_PROFILE_INFO", in: html)
        return Self.room(fromRoomData: roomData, profile: profile, fallbackID: roomID)
    }

    /// Pure parser for the TT_ROOM_DATA / TT_PROFILE_INFO pair.
    /// Testable without the network.
    static func room(fromRoomData roomData: JSONValue, profile: JSONValue?, fallbackID: String) -> LiveRoom {
        let id = roomData["profileRoom"].stringValue ?? fallbackID
        return LiveRoom(
            id: "huya-\(id)",
            platform: .huya,
            roomID: id,
            title: roomData["introduction"].stringValue ?? "",
            anchorName: profile?["nick"].stringValue ?? "",
            anchorAvatarURL: URL(string: profile?["avatar"].stringValue ?? ""),
            coverURL: Self.httpURL(roomData["screenshot"].stringValue),
            categoryName: roomData["gameFullName"].stringValue,
            viewerCount: roomData["totalCount"].intValue ?? 0,
            isLive: roomData["state"].stringValue == "ON" || roomData["isOn"].boolValue == true
        )
    }

    // MARK: - Play URLs

    func playURLs(roomID: String) async throws -> [PlayStream] {
        let html = try await roomPage(roomID: roomID)
        guard let stream = Self.extractStreamObject(in: html) else { return [] }
        return Self.streams(fromStreamObject: stream)
    }

    /// Pure parser for the hyPlayerConfig.stream object: one HLS
    /// stream per CDN line (scheme upgraded to https for ATS).
    /// Testable without the network.
    static func streams(fromStreamObject stream: JSONValue) -> [PlayStream] {
        let first = stream["data"][0]
        guard !first.isNull else { return [] }
        var streams: [PlayStream] = []
        for entry in first["gameStreamInfoList"].arrayValue {
            guard let hlsBase = entry["sHlsUrl"].stringValue,
                  let streamName = entry["sStreamName"].stringValue,
                  let suffix = entry["sHlsUrlSuffix"].stringValue,
                  let antiCode = entry["sHlsAntiCode"].stringValue,
                  !hlsBase.isEmpty, !streamName.isEmpty else { continue }
            var urlString = "\(hlsBase)/\(streamName).\(suffix)?\(antiCode)"
            if urlString.hasPrefix("http://") {
                urlString = "https://" + urlString.dropFirst("http://".count)
            }
            // Pure Live: the anti-code sometimes omits the codec; the
            // CDN then serves a codec the player cannot use. Force AVC.
            if !urlString.contains("codec=") {
                urlString += "&codec=264"
            }
            guard let url = URL(string: urlString) else { continue }
            let cdn = entry["sCdnType"].stringValue ?? ""
            streams.append(PlayStream(
                url: url,
                quality: "自适应",
                line: Self.cdnNames[cdn] ?? (cdn.isEmpty ? "主线路" : cdn)
            ))
        }
        return streams
    }

    // MARK: - Danmaku

    func sampleDanmaku(roomID: String) async -> [DanmakuItem] {
        [] // no live channel yet; never show fake lines as live danmaku
    }

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return HuyaDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Page helpers

    private func roomPage(roomID: String) async throws -> String {
        let data = try await http.get("\(Self.webBase)/\(roomID)")
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return html
    }

    /// Extract a plain JSON object that follows a marker such as
    /// "TT_ROOM_DATA = " in the page HTML. Testable without the network.
    static func extractObject(after marker: String, in html: String) -> JSONValue? {
        guard let markerRange = html.range(of: marker) else { return nil }
        guard let openIndex = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        guard let text = HaoText.extractJSONObject(html, from: openIndex),
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return json
    }

    /// Extract the hyPlayerConfig.stream object (pure JSON) from the page.
    /// Testable without the network.
    static func extractStreamObject(in html: String) -> JSONValue? {
        guard let cfgRange = html.range(of: "hyPlayerConfig") else { return nil }
        let tail = String(html[cfgRange.upperBound...])
        guard let streamRange = tail.range(of: "stream:") else { return nil }
        guard let openIndex = tail[streamRange.upperBound...].firstIndex(of: "{") else { return nil }
        guard let text = HaoText.extractJSONObject(tail, from: openIndex),
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return json
    }

    // MARK: - Mapping helpers

    /// Pure parser for a list item (recommend / category / search).
    /// Testable without the network.
    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let roomID = item["profileRoom"].stringValue ?? item["roomId"].stringValue ?? ""
        return LiveRoom(
            id: "huya-\(roomID)",
            platform: .huya,
            roomID: roomID,
            title: HaoText.firstNonEmpty(item["introduction"].stringValue, item["roomName"].stringValue) ?? "",
            anchorName: item["nick"].stringValue ?? "",
            anchorAvatarURL: httpURL(item["avatar180"].stringValue),
            coverURL: httpURL(item["screenshot"].stringValue),
            categoryName: item["gameFullName"].stringValue,
            viewerCount: item["totalCount"].intValue ?? 0,
            isLive: true
        )
    }

    private static func httpURL(_ string: String?) -> URL? {
        guard var s = string, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }
}
