// SixRoomSite.swift
// HAo Live — 六间房 (v.6.cn) adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   list    GET https://v.6.cn/ — lobby HTML embedding
//           window.__SMARTY_ALL_VARIABLES__ = {...} whose typeList[]
//           (array, or a JSON string) holds every live room:
//           rid/uid/liveid/username/livetitle/picuser/pospic/
//           anchor_area/count. Verified: 200, 157 rows. The lobby
//           is one snapshot for all categories (90s cache, local
//           paging, 30/page).
//   search  GET https://v.6.cn/search.php?type=use&key= — HTML,
//           .page-search-user ul.search-user > li[data-uid] (an
//           <i class="live"> marks a live room).
//   detail  GET https://v.6.cn/{rid} (room page) -> regex
//           rid:'{uid}',roomid:'{rid}' takes the uid; then POST
//           https://v.6.cn/coop/mobile/index.php?padapi=
//           coop-mobile-inroom.php (form: av=3.1, encpass=,
//           logiuid=, project=v6iphone, rate=1, rid=, ruid={uid};
//           iOS UA) -> {flag: "001", content: {roominfo, liveinfo,
//           roomParamInfo}}; the playable URL is built, not fetched:
//           https://wlive.6rooms.com/httpflv/{flvTitle}.flv where
//           flvTitle matches ^v{uid}-{liveId}(-many)?$ — one FLV
//           tier, "原画". Private rooms (isPriveRoom) and black-screen
//           rooms (blackScreenInfo.msg) are unplayable and skipped.
//   Categories are the 6 fixed areas (全部/歌区/舞区/脱口秀/星颜/
//   派对), filtered locally on anchor_area.
// Danmaku: SixRoom chat WebSocket — see SixRoomDanmaku.swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SixRoomSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .sixroom
    private let http = HTTPClient.shared

    private static let webBase = "https://v.6.cn"
    private static let mobileBase = "https://ios.6.cn"
    private static let mediaBase = "https://wlive.6rooms.com"
    private static let pageSize = 30
    private static let cacheLifetime: TimeInterval = 90

    private static var webHeaders: [String: String] {
        [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "Referer": "\(webBase)/",
        ]
    }

    private static let mobileUA = "ios/7.830 (ios 17.0; ; iPhone 15 (A2846/A3089/A3090/A3092))"

    private static var mobileHeaders: [String: String] {
        [
            "Accept": "application/json,text/plain,*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "Referer": "\(mobileBase)/?ver=8.0.3&build=4",
        ]
    }

    /// Fixed categories (id, name, anchor_area filter; nil = all).
    static let fixedCategories: [(id: String, name: String, area: String?)] = [
        ("all", "全部", nil),
        ("song", "歌区", "歌区"),
        ("dance", "舞区", "舞区"),
        ("talk", "脱口秀", "脱口秀"),
        ("face", "星颜", "星颜"),
        ("party", "派对", "派对"),
    ]

    /// Lobby snapshot cache + roomId -> uid map (detail needs the uid).
    private var cachedRooms: [LiveRoom] = []
    private var cachedAt: Date?
    private var knownUserIDs: [String: String] = [:]

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        Self.fixedCategories.map {
            LiveCategory(id: "sixroom-\($0.id)", platform: .sixroom, name: $0.name, iconName: nil, iconURL: nil)
        }
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await directoryPage(page: 1, categoryID: "all")
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await directoryPage(page: page, categoryID: "all")
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await directoryPage(page: 1, categoryID: Self.categoryID(of: category))
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await directoryPage(page: page, categoryID: Self.categoryID(of: category))
    }

    private func directoryPage(page: Int, categoryID: String) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let rooms = try await snapshot(forceRefresh: page == 1 && categoryID == "all")
        let area = Self.fixedCategories.first { $0.id == categoryID }?.area
        let filtered = area == nil ? rooms : rooms.filter { $0.categoryName == area }
        let start = (page - 1) * Self.pageSize
        guard start < filtered.count else { return [] }
        return Array(filtered[start..<min(filtered.count, start + Self.pageSize)])
    }

    /// The lobby snapshot (90s cache; force-refresh on page 1 of 全部).
    private func snapshot(forceRefresh: Bool) async throws -> [LiveRoom] {
        if !forceRefresh, let at = cachedAt, Date().timeIntervalSince(at) < Self.cacheLifetime, !cachedRooms.isEmpty {
            return cachedRooms
        }
        let data = try await http.get("\(Self.webBase)/", headers: Self.webHeaders)
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        let (rooms, userIDs) = try Self.parseDirectoryHTML(html)
        cachedRooms = rooms
        cachedAt = Date()
        for (roomID, uid) in userIDs { knownUserIDs[roomID] = uid }
        return rooms
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

    /// HTML search; no server paging (page > 1 is empty). A bare
    /// room id goes straight to detail.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 80, page == 1 else { return [] }
        if Self.validRoomID(query) != nil {
            if let detail = try? await roomDetail(roomID: query) {
                return [detail]
            }
            return []
        }
        let url = Self.urlWithQuery("\(Self.webBase)/search.php", [("type", "use"), ("key", query)])
        let data = try await http.get(url, headers: Self.webHeaders)
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        let (rooms, userIDs) = Self.parseSearchHTML(html)
        for (roomID, uid) in userIDs { knownUserIDs[roomID] = uid }
        return rooms
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let id = Self.validRoomID(roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let detail = try await fetchRoom(id)
        return Self.room(fromRoomDetail: detail)
    }

    /// Room detail payload (roominfo / liveinfo / params + media).
    struct RoomDetail {
        let roomID: String
        let userID: String
        let liveID: String
        let nick: String
        let title: String
        let avatar: URL?
        let cover: URL?
        let category: String?
        let followers: Int
        let isLive: Bool
        /// Built FLV URL; nil when restricted / offline / unbuildable.
        let mediaURL: URL?
    }

    private func fetchRoom(_ roomID: String) async throws -> RoomDetail {
        var userID = knownUserIDs[roomID] ?? ""
        if userID.isEmpty {
            let data = try await http.get("\(Self.webBase)/\(roomID)", headers: Self.webHeaders)
            guard let html = String(data: data, encoding: .utf8),
                  let uid = Self.parseRoomUserID(html, roomID: roomID) else {
                throw LiveSiteError.roomNotFound(roomID)
            }
            userID = uid
            knownUserIDs[roomID] = uid
        }
        var inroomHeaders = Self.mobileHeaders
        inroomHeaders["User-Agent"] = Self.mobileUA
        let json = try await http.postFormJSON(
            "\(Self.webBase)/coop/mobile/index.php?padapi=coop-mobile-inroom.php",
            fields: [
                "av": "3.1", "encpass": "", "logiuid": "",
                "project": "v6iphone", "rate": "1", "rid": "", "ruid": userID,
            ],
            headers: inroomHeaders
        )
        return try Self.parseRoomJSON(json, roomID: roomID, userID: userID)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let id = Self.validRoomID(room.roomID) else { return [] }
        let detail: RoomDetail
        do {
            detail = try await fetchRoom(id)
        } catch {
            return []
        }
        guard detail.isLive, let url = detail.mediaURL else { return [] }
        return [PlayStream(
            url: url,
            quality: "原画",
            line: "主线路",
            headers: [
                "User-Agent": Self.mobileUA,
                "Origin": Self.webBase,
                "Referer": "\(Self.webBase)/\(id)",
            ]
        )]
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return SixRoomDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Pure parsers

    /// Room ids are 2–12 digits, first digit non-zero.
    static func validRoomID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, value.count <= 12,
              value.first.map({ $0 != "0" }) == true,
              value.allSatisfy({ $0.isNumber }) else { return nil }
        return value
    }

    /// User ids are 2–13 digits, first digit non-zero.
    static func validUserID(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count >= 2 && value.count <= 13
            && value.first.map({ $0 != "0" }) == true
            && value.allSatisfy({ $0.isNumber })
    }

    static func categoryID(of category: LiveCategory) -> String {
        let id = category.id.hasPrefix("sixroom-") ? String(category.id.dropFirst("sixroom-".count)) : category.id
        return fixedCategories.contains { $0.id == id } ? id : "all"
    }

    /// Parse the lobby HTML. Returns the rooms plus their uid map.
    /// Throws when the embedded JSON is missing or yields no rooms.
    static func parseDirectoryHTML(_ html: String) throws -> (rooms: [LiveRoom], userIDs: [String: String]) {
        let marker = "window.__SMARTY_ALL_VARIABLES__ = "
        guard let markerRange = html.range(of: marker),
              let openIndex = html[markerRange.upperBound...].firstIndex(of: "{"),
              let text = HaoText.extractJSONObject(html, from: openIndex),
              let data = text.data(using: .utf8),
              let root = JSONValue.parse(data) else {
            throw LiveSiteError.invalidResponse
        }
        var typeList = root["typeList"]
        if let encoded = typeList.stringValue, encoded.hasPrefix("["),
           let innerData = encoded.data(using: .utf8),
           let inner = JSONValue.parse(innerData) {
            typeList = inner
        }
        guard typeList.arrayValue.count > 0 else { throw LiveSiteError.invalidResponse }
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        var userIDs: [String: String] = [:]
        for row in typeList.arrayValue {
            guard let roomID = validRoomID(row["rid"].stringValue ?? ""),
                  validUserID(row["uid"].stringValue ?? ""),
                  seen.insert(roomID).inserted else { continue }
            let uid = row["uid"].stringValue ?? ""
            let nick = row["username"].stringValue ?? "六间房"
            let title = HaoText.firstNonEmpty(row["livetitle"].stringValue, row["userMood"].stringValue, nick) ?? nick
            rooms.append(LiveRoom(
                id: "sixroom-\(roomID)",
                platform: .sixroom,
                roomID: roomID,
                title: title,
                anchorName: nick,
                anchorAvatarURL: Self.imageURL(row["picuser"].stringValue),
                coverURL: Self.imageURL(HaoText.firstNonEmpty(row["pospic"].stringValue, row["pic"].stringValue, row["pospic_sp"].stringValue)),
                categoryName: row["anchor_area"].stringValue,
                viewerCount: row["count"].intValue ?? 0,
                isLive: true
            ))
            userIDs[roomID] = uid
        }
        guard !rooms.isEmpty else { throw LiveSiteError.invalidResponse }
        return (rooms, userIDs)
    }

    /// Parse the search HTML. Returns the rooms plus their uid map.
    /// [] when the result block is absent (no matches).
    static func parseSearchHTML(_ html: String) -> (rooms: [LiveRoom], userIDs: [String: String]) {
        guard html.contains("page-search-user") else { return ([], [:]) }
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        var userIDs: [String: String] = [:]
        for chunk in html.components(separatedBy: "<li") {
            guard let uid = Self.firstGroup(#"data-uid="([1-9]\d{1,12})""#, in: chunk),
                  validUserID(uid) else { continue }
            guard let href = Self.firstGroup(#"<a[^>]*href="([^"]+)""#, in: chunk),
                  let roomID = Self.roomID(fromLink: href),
                  seen.insert(roomID).inserted else { continue }
            let nick = Self.firstGroup(#"class="alias"[^>]*>([^<]+)<"#, in: chunk)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "六间房"
            let avatar = Self.firstGroup(#"<img[^>]*data-src="([^"]+)""#, in: chunk)
                ?? Self.firstGroup(#"<img[^>]*src="([^"]+)""#, in: chunk)
            let isLive = chunk.contains("class=\"live\"") || chunk.contains("class='live'")
            rooms.append(LiveRoom(
                id: "sixroom-\(roomID)",
                platform: .sixroom,
                roomID: roomID,
                title: nick,
                anchorName: nick,
                anchorAvatarURL: Self.imageURL(avatar),
                coverURL: nil,
                categoryName: nil,
                viewerCount: 0,
                isLive: isLive
            ))
            userIDs[roomID] = uid
        }
        return (rooms, userIDs)
    }

    /// Room id from a room / profile link path.
    static func roomID(fromLink href: String) -> String? {
        let path = href.hasPrefix("http") ? (URL(string: href)?.path ?? href) : href
        let segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if segments.count == 1 {
            return validRoomID(segments[0])
        }
        if segments.count == 2, segments[0].lowercased() == "profile" {
            return validRoomID(segments[1])
        }
        return nil
    }

    /// The uid from a room page: rid:'{uid}',roomid:'{rid}' where
    /// the roomid matches. Nil when the page is not that room.
    static func parseRoomUserID(_ html: String, roomID: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"rid\s*:\s*['"]([1-9]\d{1,12})['"]\s*,\s*roomid\s*:\s*['"]([1-9]\d{1,11})['"]"#) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges >= 3,
                  let ridRange = Range(match.range(at: 2), in: html),
                  String(html[ridRange]) == roomID,
                  let uidRange = Range(match.range(at: 1), in: html) else { continue }
            return String(html[uidRange])
        }
        return nil
    }

    /// Parse the coop-mobile-inroom payload into a RoomDetail.
    static func parseRoomJSON(_ json: JSONValue, roomID: String, userID: String) throws -> RoomDetail {
        guard json["flag"].stringValue == "001" else { throw LiveSiteError.invalidResponse }
        let content = json["content"]
        let roomInfo = content["roominfo"]
        let liveInfo = content["liveinfo"]
        let params = content["roomParamInfo"]
        guard !content.isNull, !roomInfo.isNull, !liveInfo.isNull, !params.isNull else {
            throw LiveSiteError.invalidResponse
        }
        guard roomInfo["rid"].stringValue == roomID,
              (roomInfo["id"].stringValue ?? params["uid"].stringValue) == userID else {
            throw LiveSiteError.invalidResponse
        }
        let liveID = liveInfo["id"].stringValue ?? ""
        let flvTitle = liveInfo["flvtitle"].stringValue ?? ""
        let isPrivate = content["isPriveRoom"].boolValue == true
        let blackScreen = content["blackScreenInfo"]["msg"].stringValue ?? ""
        let restricted = isPrivate || !blackScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isLive = !restricted && !liveID.isEmpty && !flvTitle.isEmpty
        let nick = HaoText.firstNonEmpty(roomInfo["alias"].stringValue, "六间房") ?? "六间房"
        let title = HaoText.firstNonEmpty(liveInfo["title"].stringValue, roomInfo["userMood"].stringValue, nick) ?? nick
        let mediaURL: URL? = (isLive ? Self.mediaURL(userID: userID, liveID: liveID, flvTitle: flvTitle) : nil)
        return RoomDetail(
            roomID: roomID,
            userID: userID,
            liveID: liveID,
            nick: nick,
            title: title,
            avatar: Self.imageURL(HaoText.firstNonEmpty(roomInfo["headPicUrl"].stringValue, roomInfo["picuser"].stringValue)),
            cover: Self.imageURL(HaoText.firstNonEmpty(liveInfo["spredPic"].stringValue, liveInfo["pospic"].stringValue, liveInfo["largepic"].stringValue, liveInfo["pic"].stringValue)),
            category: HaoText.firstNonEmpty(roomInfo["anchor_area"].stringValue, roomInfo["rtypename"].stringValue),
            followers: params["fans_num"].intValue ?? 0,
            isLive: isLive,
            mediaURL: mediaURL
        )
    }

    static func room(fromRoomDetail detail: RoomDetail) -> LiveRoom {
        LiveRoom(
            id: "sixroom-\(detail.roomID)",
            platform: .sixroom,
            roomID: detail.roomID,
            title: detail.title,
            anchorName: detail.nick,
            anchorAvatarURL: detail.avatar,
            coverURL: detail.cover,
            categoryName: detail.category,
            viewerCount: 0,
            isLive: detail.isLive
        )
    }

    /// The playable FLV URL, built only when flvTitle matches
    /// ^v{uid}-{liveId}(-many)?$ exactly.
    static func mediaURL(userID: String, liveID: String, flvTitle: String) -> URL? {
        guard validUserID(userID), validUserID(liveID) else { return nil }
        let plain = "v\(userID)-\(liveID)"
        guard flvTitle == plain || flvTitle == plain + "-many" else { return nil }
        return URL(string: "\(mediaBase)/httpflv/\(flvTitle).flv")
    }

    /// First capture group of the first match; nil when no match.
    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Build a URL with percent-encoded query items.
    static func urlWithQuery(_ base: String, _ params: [(String, String)]) -> String {
        guard var components = URLComponents(string: base) else { return base }
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.string ?? base
    }
}
