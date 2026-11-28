// SeventeenLiveSite.swift
// HAo Live — 17LIVE adapter (anonymous, no login).
// Endpoints (Pure Live's seventeenlive_api.dart; VM verification
// 2026-11-28: api-dsa.17app.co answers HTTP 502 from this VM on
// EVERY variant tried — sections count=3/20, with/without an empty
// cursor, region JP/TW, search, and /lives/{id}, with and without
// the ja-JP + Origin/Referer headers. Google's frontend returns
// the 502, so this is the VM egress, not the code path — the
// adapter is written to the reference contract and needs a
// domestic real-device check):
//   list    GET api-dsa.17app.co/api/v1/sections?count=20
//           &typeTab=2&region=JP&cursor= (cursor paging; skip
//           TopBanner / ArchiveVideo / Vod sections, take
//           grids[].stream; liveStreamID is the room id)
//   search  GET api-dsa.17app.co/api/v1/liveStreams/search?query=
//           (current-live results, no cursor)
//   detail  GET api-dsa.17app.co/api/v1/lives/{liveStreamID}
//           -> room + streams (status 2 = live, 0 = offline;
//           pullURLsInfo.rtmpURLs[] / rtmpUrls[] carry the FLV
//           lines: urlQualityEnhancedHD / urlLowBitrateHD /
//           webUrl / url / url264 / urlLowQuality /
//           webUrlLowQuality / urlHighQuality)
//   Headers: Accept-Language ja-JP + Origin/Referer
//           https://17.live on catalogue calls.
// Streams are FLV (pull-rtmp*.17app.co, .flv path) — used
// verbatim. premiumContent premiumType 1 (paid) / 2
// (subscribers-only) rooms are listed but yield no streams.
// Danmaku: Ably channel, see SeventeenLiveDanmaku.swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SeventeenLiveSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .seventeenlive
    private let http = HTTPClient.shared

    private static let apiBase = "https://api-dsa.17app.co/api/v1"
    private static let origin = "https://17.live"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private static var catalogHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "ja-JP,ja;q=0.9,en;q=0.8",
            "Origin": origin,
            "Referer": "\(origin)/",
        ]
    }

    private static func roomHeaders(roomID: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": origin,
            "Referer": "https://17.live/en/live/\(roomID)",
        ]
    }

    private static func mediaHeaders(roomID: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Origin": origin,
            "Referer": "https://17.live/en/live/\(roomID)",
        ]
    }

    // MARK: - Lists

    /// No category tree on 17LIVE (sections are curated rows,
    /// not browsable categories).
    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] {
        let page = try await directory(cursor: nil)
        return page.rooms
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1, page <= 20 else { return [] }
        var cursor: String? = nil
        for current in 1...page {
            let result = try await directory(cursor: cursor)
            if current == page { return result.rooms }
            guard let next = result.nextCursor else { return [] }
            cursor = next
        }
        return []
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await recommendRooms()
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await recommendRooms(page: page)
    }

    /// One sections page: live rooms + the next cursor (nil at
    /// the end). Banner / archive / VOD sections are skipped.
    private func directory(cursor: String?) async throws -> (rooms: [LiveRoom], nextCursor: String?) {
        var url = "\(Self.apiBase)/sections?count=20&typeTab=2&region=JP&cursor="
        if let cursor { url += cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor }
        let json = try await http.getJSON(url, headers: Self.catalogHeaders)
        return Self.directory(fromJSON: json, cursor: cursor)
    }

    /// Pure parser for a sections response. Testable without the network.
    static func directory(fromJSON json: JSONValue, cursor: String?) -> (rooms: [LiveRoom], nextCursor: String?) {
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for section in json["sections"].arrayValue {
            let sectionID = section["id"].stringValue ?? ""
            if sectionID == "TopBanner" || sectionID == "ArchiveVideo" || sectionID == "Vod" { continue }
            for grid in section["grids"].arrayValue {
                let stream = grid["stream"]
                guard !stream.isNull,
                      let roomID = stream["liveStreamID"].stringValue ?? stream["liveStreamID"].intValue.map(String.init),
                      let room = Self.room(fromData: stream, requestedID: roomID, includeStreams: false),
                      room.isLive, seen.insert(roomID).inserted else { continue }
                rooms.append(room)
            }
        }
        let rawCursor = json["cursor"].stringValue
        let nextCursor: String? = {
            guard let raw = rawCursor, !raw.isEmpty, raw != cursor else { return nil }
            return raw
        }()
        return (rooms: rooms, nextCursor: nextCursor)
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    /// Page 1 only (the search endpoint has no cursor). A bare
    /// numeric room id or a 17.live link resolves straight to
    /// that room.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        guard page == 1 else { return [] }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100 else { return [] }
        if let roomID = Self.roomID(from: query) {
            if let room = try? await roomDetail(roomID: roomID) {
                return [room]
            }
            return []
        }
        guard !query.lowercased().hasPrefix("http://"),
              !query.lowercased().hasPrefix("https://") else { return [] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let json = try await http.getJSON(
            "\(Self.apiBase)/liveStreams/search?query=\(encoded)", headers: Self.catalogHeaders)
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for row in json.arrayValue {
            guard let roomID = row["liveStreamID"].stringValue ?? row["liveStreamID"].intValue.map(String.init),
                  let room = Self.room(fromData: row, requestedID: roomID, includeStreams: false),
                  room.isLive, seen.insert(roomID).inserted else { continue }
            rooms.append(room)
        }
        return rooms
    }

    /// Normalize a room id from a bare id or a 17.live link
    /// (/live/{id}, /{locale}/live/{id}, /profile/r/{id}).
    /// Testable without the network.
    static func roomID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isValidRoomID(text) { return text }
        guard let url = URL(string: text),
              let host = url.host?.lowercased(),
              host == "17.live" || host == "www.17.live" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count == 2, segments[0].lowercased() == "live" {
            return Self.isValidRoomID(segments[1]) ? segments[1] : nil
        }
        if segments.count == 3, segments[1].lowercased() == "live" {
            return Self.isValidRoomID(segments[2]) ? segments[2] : nil
        }
        if segments.count == 3, segments[0].lowercased() == "profile", segments[1].lowercased() == "r" {
            return Self.isValidRoomID(segments[2]) ? segments[2] : nil
        }
        if segments.count == 4, segments[1].lowercased() == "profile", segments[2].lowercased() == "r" {
            return Self.isValidRoomID(segments[3]) ? segments[3] : nil
        }
        return nil
    }

    static func isValidRoomID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 12, text.first != "0",
              text.allSatisfy({ $0.isNumber }) else { return false }
        return true
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let id = Self.roomID(from: roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let json = try await http.getJSON(
            "\(Self.apiBase)/lives/\(id)", headers: Self.roomHeaders(roomID: id))
        guard let room = Self.room(fromData: json, requestedID: id, includeStreams: true) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return room
    }

    /// Pure parser for a room object (directory row, search row or
    /// /lives/{id} body). Nil when the id does not match the
    /// request, the owner id disagrees, or the state is unknown.
    /// Testable without the network.
    static func room(fromData data: JSONValue, requestedID: String, includeStreams: Bool) -> LiveRoom? {
        guard let responseID = data["liveStreamID"].stringValue ?? data["liveStreamID"].intValue.map(String.init),
              responseID == requestedID else { return nil }
        let user = data["userInfo"]
        guard !user.isNull else { return nil }
        if let ownerRoomID = user["roomID"].stringValue ?? user["roomID"].intValue.map(String.init),
           ownerRoomID != requestedID { return nil }
        guard let userID = data["userID"].stringValue,
              user["userID"].stringValue == userID else { return nil }
        let status = data["status"].intValue
        let isLive: Bool
        switch status {
        case 2: isLive = true
        case 0: isLive = false
        default: return nil
        }
        let nick = HaoText.firstNonEmpty(user["displayName"].stringValue, user["openID"].stringValue) ?? ""
        guard !nick.isEmpty else { return nil }
        let title = HaoText.firstNonEmpty(data["caption"].stringValue, nick) ?? nick
        let restricted = isRestricted(data["premiumContent"])
        var playData: String? = nil
        if includeStreams, isLive, !restricted {
            let streams = streams(fromData: data)
            if !streams.isEmpty {
                playData = streamsJSON(streams)
            }
        }
        return LiveRoom(
            id: "seventeenlive-\(requestedID)",
            platform: .seventeenlive,
            roomID: requestedID,
            title: title,
            anchorName: nick,
            anchorAvatarURL: imageURL17(user["picture"].stringValue),
            coverURL: imageURL17(HaoText.firstNonEmpty(
                data["coverPhoto"].stringValue, data["thumbnail"].stringValue)),
            categoryName: data["audioOnly"].intValue == 1 ? "纯音频" : nil,
            viewerCount: isLive
                ? (data["liveViewerCount"].intValue ?? data["viewerCount"].intValue ?? 0) : 0,
            isLive: isLive,
            playDataJSON: playData
        )
    }

    /// premiumContent premiumType: 0 = free, 1 = paid, 2 =
    /// subscribers-only (unpaid). Anything else unplayable.
    static func isRestricted(_ premium: JSONValue) -> Bool {
        guard !premium.isNull else { return false }
        let type = premium["premiumType"].intValue ?? 0
        if type == 0 { return false }
        if let payment = premium["paymentInfo"].objectValue["paid"]?.boolValue, payment == true {
            return false
        }
        return true
    }

    /// 17LIVE image URLs: a bare path is served from
    /// cdn.17app.co; only the two known hosts are accepted.
    /// Testable without the network.
    static func imageURL17(_ string: String?) -> URL? {
        guard var s = string, !s.isEmpty else { return nil }
        if !s.contains("://") {
            guard !s.contains("..") else { return nil }
            s = "https://cdn.17app.co/" + (s.hasPrefix("/") ? String(s.dropFirst()) : s)
        }
        guard let url = URL(string: s),
              let host = url.host?.lowercased(),
              host == "cdn.17app.co" || host == "assets-17app.akamaized.net" else { return nil }
        return Self.imageURL(s)
    }

    // MARK: - Play URLs

    /// FLV lines, best quality first. The detail call is made
    /// fresh every time (streams are signed and short-lived).
    /// Paid / subscribers-only / offline rooms yield [].
    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let id = Self.roomID(from: room.roomID) else { return [] }
        // Fast path: streams carried from roomDetail.
        if let playData = room.playDataJSON,
           let streams = Self.streams(fromPlayDataJSON: playData),
           !streams.isEmpty {
            return streams.map { stream in
                PlayStream(url: stream.url, quality: stream.quality, line: "主线路",
                           headers: Self.mediaHeaders(roomID: id))
            }
        }
        let detail = try await roomDetail(roomID: id)
        guard detail.isLive,
              let playData = detail.playDataJSON,
              let streams = Self.streams(fromPlayDataJSON: playData),
              !streams.isEmpty else { return [] }
        return streams.map { stream in
            PlayStream(url: stream.url, quality: stream.quality, line: "主线路",
                       headers: Self.mediaHeaders(roomID: id))
        }
    }

    /// One quality tier from /lives/{id}.
    struct StreamTier {
        let quality: String
        let url: URL
    }

    /// Pure parser for the stream tiers of a /lives/{id} body:
    /// pullURLsInfo.rtmpURLs[] (or rtmpUrls[]) mapped to
    /// enhanced > hd > h264 > standard. URLs must be https FLV
    /// from pull-rtmp*.17app.co and are used verbatim. Testable
    /// without the network.
    static func streams(fromData data: JSONValue) -> [StreamTier] {
        var providers: [JSONValue] = []
        let pull = data["pullURLsInfo"]
        if !pull.isNull {
            providers = pull["rtmpURLs"].arrayValue
        }
        if providers.isEmpty {
            providers = data["rtmpUrls"].arrayValue
        }
        // quality id -> (display name, [urls]) in first-seen order.
        var tiers: [(id: String, name: String, urls: [URL])] = []
        func add(_ qualityID: String, _ name: String, _ value: JSONValue) {
            guard let raw = value.stringValue, !raw.isEmpty,
                  let url = mediaURL(raw) else { return }
            if let index = tiers.firstIndex(where: { $0.id == qualityID }) {
                if !tiers[index].urls.contains(url) { tiers[index].urls.append(url) }
            } else {
                tiers.append((id: qualityID, name: name, urls: [url]))
            }
        }
        for provider in providers {
            add("enhanced", "超高清", provider["urlQualityEnhancedHD"])
            add("hd", "高清", provider["urlLowBitrateHD"])
            add("hd", "高清", provider["webUrl"])
            add("hd", "高清", provider["url"])
            add("h264", "H.264", provider["url264"])
            add("standard", "流畅", provider["urlLowQuality"])
            add("standard", "流畅", provider["webUrlLowQuality"])
            add("standard", "流畅", provider["urlHighQuality"])
        }
        let order = ["enhanced": 0, "hd": 1, "h264": 2, "standard": 3]
        return tiers
            .sorted { (order[$0.id] ?? 99) < (order[$1.id] ?? 99) }
            .flatMap { tier in tier.urls.map { StreamTier(quality: tier.name, url: $0) } }
    }

    /// Validate a stream URL (https, pull-rtmp*.17app.co, .flv)
    /// and return it VERBATIM. Testable without the network.
    static func mediaURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, !raw.contains(" "),
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host.hasSuffix(".17app.co"), host.contains("pull-rtmp"),
              url.path.lowercased().hasSuffix(".flv") else { return nil }
        return url
    }

    /// Encode tiers as playDataJSON (carried on the room from
    /// roomDetail so playURLs can skip a re-fetch when fresh).
    static func streamsJSON(_ tiers: [StreamTier]) -> String? {
        let items = tiers.map { tier in
            "{\"quality\":\"\(tier.quality)\",\"url\":\"\(tier.url.absoluteString)\"}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    /// Decode playDataJSON back into tiers.
    static func streams(fromPlayDataJSON text: String) -> [StreamTier]? {
        guard let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        let tiers = json.arrayValue.compactMap { item -> StreamTier? in
            guard let quality = item["quality"].stringValue,
                  let raw = item["url"].stringValue,
                  let url = URL(string: raw) else { return nil }
            return StreamTier(quality: quality, url: url)
        }
        return tiers.isEmpty ? nil : tiers
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return SeventeenLiveDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }
}
