// KilakilaSite.swift
// HAo Live — Kilakila adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   timeline  GET live.kilakila.cn/pcLive/timeline?tag=0&type=0
//             &genderType=0&pageNo=1&pageSize=3
//             -> {code: 200, data: {body: {h: {code: 200, success: true},
//                b: {pageNo, pageSize, isLastPage, data: [{dataType,
//                roomResq: {roomIdStr, uid, title, status, goldPrice,
//                backPic, watchNumber}, userResp: {id, nickname,
//                headPortraitUrl}}]}}}} (3 rows, all dataType 8,
//                status 4, goldPrice 0)
//   recommend GET live.kilakila.cn/pcLive/recommend
//             -> same envelope, but b may be ABSENT on success.
//   search    GET live.kilakila.cn/aboutus/serach/kw/{keyword}
//             (the path really is spelled "serach") -> HTML,
//             .userList > a[href="/zhubo/{uid}"] + .anchor-name.
//   owner     GET live.hongrenshuo.com.cn/Tg/personalH5?uid=
//             -> {code: 200, data: {userResp, liveCard:
//                {roomIdStr, uid, status, ...}}} (liveCard with only
//                roomSourceType/recommendSource keys = no live room;
//                code 1013 = unknown account)
//   detail    GET live.kilakila.cn/LiveRoom/getRoomInfo?roomId=
//             -> {h: {code: 200, success: true}, b: {roomIdStr, uid,
//                title, status, goldPrice, flvPlayUrl, hlsPlayUrl,
//                userInfo: {nickname, headPortraitUrl},
//                defaultBackgroundPicUrl}} — NOTE: no `data` wrapper
//                here, unlike the timeline.
// Room identity is the anchor UID (durable, Pure Live's choice);
// the broadcast roomIdStr is ephemeral and rides on
// LiveRoom.playDataJSON for playURLs / danmaku.
// Paid rooms (goldPrice != 0) are skipped: they have no playable
// stream for an anonymous viewer. Danmaku: socket.io channel,
// see KilakilaDanmaku.swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class KilakilaSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .kilakila
    private let http = HTTPClient.shared

    private static let webBase = "https://live.kilakila.cn"
    private static let ownerBase = "https://live.hongrenshuo.com.cn"
    private static let playHeaders: [String: String] = [
        "Referer": "\(webBase)/",
        "User-Agent": "Mozilla/5.0",
    ]

    // MARK: - Lists

    /// No category tree on Kilakila (the timeline has only a hot /
    /// newcomer switch, not browsable categories).
    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommend()
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        // The recommend showcase has no paging; deeper pages come
        // from the timeline directory.
        if page <= 1 { return try await recommend() }
        return try await timeline(page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await recommendRooms()
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await recommendRooms(page: page)
    }

    /// The hot timeline. Only dataType 8 rows, only status 4
    /// (live), only goldPrice 0 (free) become rooms.
    private func timeline(page: Int, pageSize: Int = 20) async throws -> [LiveRoom] {
        let url = "\(Self.webBase)/pcLive/timeline?tag=0&type=0&genderType=0&pageNo=\(page)&pageSize=\(pageSize)"
        let json = try await http.getJSON(url, headers: Self.playHeaders)
        guard json["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let body = json["data"]["body"]
        guard body["h"]["code"].intValue == 200, body["h"]["success"].boolValue == true else {
            throw LiveSiteError.invalidResponse
        }
        return Self.rooms(fromTimelineBody: body["b"])
    }

    /// The recommend showcase. Its body `b` may be absent on
    /// success (an empty showcase, not an error).
    private func recommend() async throws -> [LiveRoom] {
        let json = try await http.getJSON("\(Self.webBase)/pcLive/recommend", headers: Self.playHeaders)
        guard json["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let body = json["data"]["body"]
        guard body["h"]["code"].intValue == 200, body["h"]["success"].boolValue == true else {
            throw LiveSiteError.invalidResponse
        }
        guard !body["b"].isNull else { return [] }
        return Self.rooms(fromTimelineBody: body["b"])
    }

    /// Pure parser for a timeline body: either the page object
    /// ({data: [...]}) or a bare row array (recommend). Testable
    /// without the network.
    static func rooms(fromTimelineBody body: JSONValue) -> [LiveRoom] {
        let rows: [JSONValue]
        if !body.arrayValue.isEmpty {
            rows = body.arrayValue
        } else {
            rows = body["data"].arrayValue
        }
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for row in rows {
            guard let room = Self.room(fromTimelineRow: row),
                  seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
        }
        return rooms
    }

    /// Pure parser for one timeline row. Nil when the row is not a
    /// free live room. Testable without the network.
    static func room(fromTimelineRow row: JSONValue) -> LiveRoom? {
        guard row["dataType"].intValue == 8 else { return nil }
        let roomResq = row["roomResq"]
        let userResp = row["userResp"]
        guard let roomId = roomResq["roomIdStr"].stringValue, !roomId.isEmpty,
              let uid = roomResq["uid"].stringValue ?? userResp["id"].stringValue,
              !uid.isEmpty,
              roomResq["status"].intValue == 4,
              roomResq["goldPrice"].intValue == 0,
              let title = roomResq["title"].stringValue, !title.isEmpty,
              let nick = userResp["nickname"].stringValue, !nick.isEmpty else { return nil }
        return LiveRoom(
            id: "kilakila-\(uid)",
            platform: .kilakila,
            roomID: uid,
            title: title,
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(userResp["headPortraitUrl"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(
                roomResq["backPic"].stringValue,
                roomResq["defaultBackgroundPicUrl"].stringValue)),
            categoryName: nil,
            viewerCount: roomResq["watchNumber"].intValue ?? 0,
            isLive: true,
            playDataJSON: "{\"roomId\":\"\(roomId)\"}"
        )
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

    /// A bare numeric UID resolves straight to that anchor's
    /// current room; anything else is a nickname search over the
    /// official search page. Search results are anchor profiles
    /// (isLive false) — roomDetail resolves whether each is live.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if query.allSatisfy({ $0.isNumber }), !query.hasPrefix("0") {
            if let room = try? await roomDetail(roomID: query), room.isLive {
                return [room]
            }
            return []
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        var path = "\(Self.webBase)/aboutus/serach/kw/\(encoded)"
        if page > 1 { path += "/p/\(page)" }
        let data = try await http.get(path, headers: Self.playHeaders)
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return Self.owners(fromSearchHTML: html).map { owner in
            LiveRoom(
                id: "kilakila-\(owner.uid)",
                platform: .kilakila,
                roomID: owner.uid,
                title: owner.nick,
                anchorName: owner.nick,
                anchorAvatarURL: Self.imageURL(owner.avatar),
                coverURL: Self.imageURL(owner.avatar),
                categoryName: nil,
                viewerCount: 0,
                isLive: false
            )
        }
    }

    /// Pure parser for the search page: .userList > a[href="/zhubo/{uid}"]
    /// with .anchor-name text and .anchorHeaderImg img src.
    /// Testable without the network.
    static func owners(fromSearchHTML html: String) -> [(uid: String, nick: String, avatar: String?)] {
        var results: [(uid: String, nick: String, avatar: String?)] = []
        var seen = Set<String>()
        var searchFrom = html.startIndex
        while let anchorRange = html[searchFrom...].range(of: "<a href=\"/zhubo/") {
            let uidStart = anchorRange.upperBound
            guard let uidEnd = html[uidStart...].firstIndex(of: "\"") else { break }
            let uid = String(html[uidStart..<uidEnd])
            guard let closeRange = html[uidEnd...].range(of: "</a>") else { break }
            let block = String(html[uidEnd..<closeRange.lowerBound])
            let nick = extractText(after: "anchor-name\">", in: block)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var avatar: String?
            if let imgRange = block.range(of: "<img src=\"") {
                let srcStart = imgRange.upperBound
                if let srcEnd = block[srcStart...].firstIndex(of: "\"") {
                    avatar = String(block[srcStart..<srcEnd])
                }
            }
            if !uid.isEmpty, !nick.isEmpty, seen.insert(uid).inserted {
                results.append((uid: uid, nick: HaoText.stripTags(nick), avatar: avatar))
            }
            searchFrom = closeRange.upperBound
        }
        return results
    }

    /// Text up to the next "<" after a marker, or nil.
    static func extractText(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: "<") else { return String(tail) }
        return String(tail[..<end])
    }

    // MARK: - Room detail

    /// Anchor UID -> current broadcast. The owner endpoint is the
    /// only durable lookup: a broadcast roomIdStr is ephemeral.
    /// Returns an offline room when the anchor has no live room.
    func roomDetail(roomID: String) async throws -> LiveRoom {
        let uid = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, uid.allSatisfy({ $0.isNumber }) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let owner = try await Self.owner(uid: uid)
        guard let currentRoomID = owner.currentRoomID else {
            return LiveRoom(
                id: "kilakila-\(uid)",
                platform: .kilakila,
                roomID: uid,
                title: owner.nick,
                anchorName: owner.nick,
                anchorAvatarURL: Self.imageURL(owner.avatar),
                coverURL: Self.imageURL(owner.avatar),
                categoryName: nil,
                viewerCount: 0,
                isLive: false
            )
        }
        // Full detail carries the media URLs; fall back to the
        // liveCard row itself when getRoomInfo fails.
        if let detail = try? await Self.roomInfo(roomID: currentRoomID) {
            return Self.room(fromDetail: detail, fallbackUID: uid)
        }
        return LiveRoom(
            id: "kilakila-\(uid)",
            platform: .kilakila,
            roomID: uid,
            title: owner.currentTitle ?? owner.nick,
            anchorName: owner.nick,
            anchorAvatarURL: Self.imageURL(owner.avatar),
            coverURL: Self.imageURL(owner.currentCover),
            categoryName: nil,
            viewerCount: owner.currentWatchers ?? 0,
            isLive: owner.currentStatus == 4,
            playDataJSON: "{\"roomId\":\"\(currentRoomID)\"}"
        )
    }

    /// The anchor profile + current broadcast, if any.
    struct OwnerInfo {
        let nick: String
        let avatar: String?
        let currentRoomID: String?
        let currentStatus: Int?
        let currentTitle: String?
        let currentCover: String?
        let currentWatchers: Int?
    }

    static func owner(uid: String) async throws -> OwnerInfo {
        let json = try await HTTPClient.shared.getJSON(
            "\(ownerBase)/Tg/personalH5?uid=\(uid)", headers: playHeaders)
        if json["code"].intValue == 1013 {
            throw LiveSiteError.roomNotFound(uid)
        }
        guard json["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        return Self.owner(fromJSON: json["data"])
    }

    /// Pure parser for the owner endpoint body. Testable without
    /// the network.
    static func owner(fromJSON data: JSONValue) -> OwnerInfo {
        let user = data["userResp"]
        let card = data["liveCard"]
        // An empty card carries only routing defaults.
        let hasCurrentRoom = !card.isNull
            && !card.objectValue.keys.allSatisfy({ $0 == "roomSourceType" || $0 == "recommendSource" })
            && !(card["roomIdStr"].stringValue ?? "").isEmpty
        return OwnerInfo(
            nick: user["nickname"].stringValue ?? "",
            avatar: user["headPortraitUrl"].stringValue,
            currentRoomID: hasCurrentRoom ? card["roomIdStr"].stringValue : nil,
            currentStatus: hasCurrentRoom ? card["status"].intValue : nil,
            currentTitle: hasCurrentRoom ? card["title"].stringValue : nil,
            currentCover: hasCurrentRoom ? card["backPic"].stringValue : nil,
            currentWatchers: hasCurrentRoom ? card["watchNumber"].intValue : nil
        )
    }

    /// GET LiveRoom/getRoomInfo — returns the inner `b` object
    /// (the response has NO `data` wrapper). Throws on a business
    /// error; code 5966 is a historical replay, not a live room.
    static func roomInfo(roomID: String) async throws -> JSONValue {
        let json = try await HTTPClient.shared.getJSON(
            "\(webBase)/LiveRoom/getRoomInfo?roomId=\(roomID)", headers: playHeaders)
        guard json["h"]["code"].intValue != 5966 else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        guard json["h"]["code"].intValue == 200, json["h"]["success"].boolValue == true else {
            throw LiveSiteError.invalidResponse
        }
        return json["b"]
    }

    /// Pure parser for a getRoomInfo body. Testable without the network.
    static func room(fromDetail detail: JSONValue, fallbackUID: String) -> LiveRoom {
        let uid = detail["uid"].stringValue ?? fallbackUID
        let userInfo = detail["userInfo"]
        return LiveRoom(
            id: "kilakila-\(uid)",
            platform: .kilakila,
            roomID: uid,
            title: detail["title"].stringValue ?? "",
            anchorName: userInfo["nickname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(userInfo["headPortraitUrl"].stringValue),
            coverURL: Self.imageURL(detail["defaultBackgroundPicUrl"].stringValue),
            categoryName: nil,
            viewerCount: detail["watchNumber"].intValue ?? 0,
            isLive: detail["status"].intValue == 4,
            playDataJSON: "{\"roomId\":\"\(detail["roomIdStr"].stringValue ?? "")\"}"
        )
    }

    // MARK: - Play URLs

    /// FLV + HLS, one tier ("原画"), two lines. Signed URLs are
    /// used verbatim (auth_key kept); paid or offline rooms yield [].
    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let roomID: String
        if let carried = Self.carriedRoomID(from: room.playDataJSON), !carried.isEmpty {
            roomID = carried
        } else if let owner = try? await Self.owner(uid: room.roomID),
                  let current = owner.currentRoomID {
            roomID = current
        } else {
            return []
        }
        guard let detail = try? await Self.roomInfo(roomID: roomID),
              detail["status"].intValue == 4,
              detail["goldPrice"].intValue == 0 else { return [] }
        let headers = PlaybackHeaders.headers(platform: .kilakila, roomID: room.roomID)
        var streams: [PlayStream] = []
        if let flv = Self.mediaURL(detail["flvPlayUrl"].stringValue, roomID: roomID, ext: "flv") {
            streams.append(PlayStream(url: flv, quality: "原画", line: "FLV", headers: headers))
        }
        if let hls = Self.mediaURL(detail["hlsPlayUrl"].stringValue, roomID: roomID, ext: "m3u8") {
            streams.append(PlayStream(url: hls, quality: "原画", line: "HLS", headers: headers))
        }
        return streams
    }

    /// The broadcast roomId carried on LiveRoom.playDataJSON.
    static func carriedRoomID(from playDataJSON: String?) -> String? {
        guard let text = playDataJSON,
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return json["roomId"].stringValue
    }

    /// Validate a signed media URL (host + /hrs/{roomId}.{ext} +
    /// auth_key) and return it VERBATIM. Nil when it is not a
    /// Kilakila pull URL. Testable without the network.
    static func mediaURL(_ string: String?, roomID: String, ext: String) -> URL? {
        guard let string, !string.isEmpty,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host == "pull.live.hongrenshuo.com.cn",
              url.path == "/hrs/\(roomID).\(ext)",
              url.query?.contains("auth_key=") == true else { return nil }
        return url
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return KilakilaDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }
}
