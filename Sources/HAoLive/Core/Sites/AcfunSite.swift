// AcfunSite.swift
// HAo Live — real AcFun adapter (anonymous + anonymous visitor
// login, no account login).
// Endpoints verified live from this VM 2026-11-28:
//   list     GET live.acfun.cn/api/channel/list?count=3&pcursor=
//            -> {channelListData: {result: 0, liveList: [{authorId,
//               title, user: {name, headUrl, fanCountValue},
//               coverUrls[], onlineCount, liveId, streamName,
//               type: {id, name}, createTime,
//               paidShowUserBuyStatus}], pcursor: "1",
//               channelFilters: {liveChannelDisplayFilters:
//               [{displayFilters: [{filterType, filterId, name,
//               cover}]}]}}} (3 rooms; pcursor "1" = next page)
//   detail   GET live.acfun.cn/api/live/info?authorId=173620
//            -> {result: 0, authorId, title, liveId, streamName,
//               onlineCount, coverUrls[], type: {id, name},
//               user: {id, name, headUrl, fanCountValue},
//               paidShowUuid: null, paidShowUserBuyStatus: false}
//   visitor  POST id.app.acfun.cn/rest/app/visitor/login
//            (form {sid: "acfun.api.visitor"}, Cookie _did=web_+16)
//            -> {result: 0, userId, acfun.api.visitor_st,
//               acSecurity} (verified; token valid 5 min)
//   play     POST api.kuaishouzt.com/rest/zt/live/web/startPlay
//            ?subBiz=mainApp&kpn=ACFUN_APP&kpf=PC_WEB&userId=&did=
//            &acfun.api.visitor_st= (form {authorId,
//            pullStreamType: "FLV"}) -> {result: 1, data: {liveId,
//            availableTickets[], enterRoomAttach,
//            videoPlayRes: {liveAdaptiveManifest: [{adaptationSet:
//            {representation: [{url, qualityType, name, level,
//            bitrate, hidden}]}}]}}} (verified: STANDARD 高清 1000,
//            HIGH 超清 2000, SUPER 蓝光 4M 4000; FLV URLs carry an
//            auth_key query — used verbatim)
//   search   GET www.acfun.cn/search?keyword=&type=user&pCursor=1
//            &quickViewId=up-list&reqID=1&ajaxpipe=1
//            -> JSON {"html": "<span class=\"total-num\"
//            data-total=\"100\">…<div class=\"search-up\"
//            data-up-exposure-log='{\"up_id\":…, \"is_on_live\":
//            \"<liveId or empty>\"}'>…<img class=\"up__avatar\"
//            src=\"…\" alt=\"<name>\"/>…<span
//            class=\"info__danmaku-count\">3160&ensp;粉丝</span>…"}
//            (verified: 139 KB page, first card parsed; is_on_live
//            is the liveId when live, "" when offline)
// Paid rooms (paidShowUuid non-empty) are never listed as playable:
// list items carrying one are skipped, and roomDetail reports
// them as not live.
// Danmaku: NOT implemented in this leg. AcFun's link danmaku needs
// AES-128-CBC frame sealing (acSecurity) + a protobuf link
// protocol + gzip push decoding, and this codebase has no AES
// helper; porting it unverified would be a fake. danmakuStream
// keeps the default empty implementation — see the report.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AcfunSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .acfun
    private let http = HTTPClient.shared

    private static let origin = "https://live.acfun.cn"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private static let pageSize = 30

    /// Playback headers (Pure Live's AcfunApi.playHeaders).
    private static let playHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Referer": "\(origin)/",
    ]

    /// Quality type -> display label when the server sends no name.
    private static let qualityLabels: [String: String] = [
        "STANDARD": "高清",
        "HIGH": "超清",
        "SUPER": "蓝光",
        "BLUE_RAY": "高码率",
    ]

    // MARK: - Directory cursor chain
    //
    // The list API pages by opaque cursor (pcursor), not by number.
    // Cursors are kept in memory per filter set so recommendRooms /
    // categoryRooms can serve page N after page N-1 was fetched
    // (Pure Live's AcfunDirectory). A page with no stored cursor
    // returns [] instead of erroring — the caller pages forward.

    nonisolated(unsafe) private static var cursors: [String: [Int: String]] = [:]

    private static func cursor(for filters: String?, page: Int) -> String? {
        if page <= 1 { return "" }
        return cursors[filters ?? ""]?[page]
    }

    private static func storeCursor(_ cursor: String?, for filters: String?, page: Int) {
        guard let cursor, !cursor.isEmpty, cursor != "no_more" else { return }
        var pages = cursors[filters ?? ""] ?? [:]
        pages[page] = cursor
        cursors[filters ?? ""] = pages
    }

    private func directoryPage(count: Int, filters: String?, page: Int) async throws -> (rooms: [LiveRoom], nextCursor: String?) {
        guard let cursor = Self.cursor(for: filters, page: page) else { return ([], nil) }
        var components = URLComponents(string: "\(Self.origin)/api/channel/list")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "pcursor", value: cursor),
        ]
        if let filters { items.append(URLQueryItem(name: "filters", value: filters)) }
        components.queryItems = items
        guard let url = components.url else { throw LiveSiteError.invalidResponse }
        let json = try await http.getJSON(url.absoluteString, headers: Self.playHeaders)
        let data = json["channelListData"]
        guard data["result"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        let rooms = data["liveList"].arrayValue.compactMap(Self.room(fromDirectoryItem:))
        let next = data["pcursor"].stringValue
        Self.storeCursor(next, for: filters, page: page + 1)
        return (rooms, next)
    }

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        var components = URLComponents(string: "\(Self.origin)/api/channel/list")!
        components.queryItems = [
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "pcursor", value: ""),
        ]
        guard let url = components.url else { throw LiveSiteError.invalidResponse }
        let json = try await http.getJSON(url.absoluteString, headers: Self.playHeaders)
        return Self.categories(fromDirectoryJSON: json)
    }

    /// Pure parser for the top-level channelFilters block of a
    /// directory response. Testable without the network.
    static func categories(fromDirectoryJSON json: JSONValue) -> [LiveCategory] {
        var out: [LiveCategory] = []
        var seen: Set<String> = []
        for group in json["channelFilters"]["liveChannelDisplayFilters"].arrayValue {
            for filter in group["displayFilters"].arrayValue {
                guard let type = filter["filterType"].intValue, type >= 0,
                      let id = filter["filterId"].intValue, id > 0,
                      let name = filter["name"].stringValue, !name.isEmpty else { continue }
                let categoryID = "acfun-\(type):\(id)"
                guard seen.insert(categoryID).inserted else { continue }
                out.append(LiveCategory(id: categoryID, platform: .acfun, name: name, iconName: nil, iconURL: Self.imageURL(filter["cover"].stringValue)))
            }
        }
        return out
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        return try await directoryPage(count: Self.pageSize, filters: nil, page: page).rooms
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page >= 1,
              let (type, id) = Self.filterParts(of: category.id) else { return [] }
        let filters = "[{\"filterType\":\(type),\"filterId\":\(id)}]"
        return try await directoryPage(count: Self.pageSize, filters: filters, page: page).rooms
    }

    /// "acfun-{type}:{id}" -> (type, id).
    static func filterParts(of categoryID: String) -> (Int, Int)? {
        guard categoryID.hasPrefix("acfun-") else { return nil }
        let rest = categoryID.dropFirst("acfun-".count)
        let parts = rest.split(separator: ":").map(String.init)
        guard parts.count == 2, let type = Int(parts[0]), let id = Int(parts[1]) else { return nil }
        return (type, id)
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let anchors = try await searchAnchors(keyword: keyword, page: page)
        return anchors.filter { $0.isLive }
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchAnchors(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, page >= 1 else { return [] }
        var components = URLComponents(string: "https://www.acfun.cn/search")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "type", value: "user"),
            URLQueryItem(name: "pCursor", value: String(page)),
            URLQueryItem(name: "quickViewId", value: "up-list"),
            URLQueryItem(name: "reqID", value: "1"),
            URLQueryItem(name: "ajaxpipe", value: "1"),
        ]
        guard let url = components.url else { throw LiveSiteError.invalidResponse }
        let data = try await http.get(url.absoluteString, headers: [
            "User-Agent": Self.userAgent,
            "Referer": "https://www.acfun.cn/search",
        ])
        guard let body = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return Self.rooms(fromSearchBody: body)
    }

    /// Pure parser for the BigPipe search page: the JSON head (up to
    /// the fetch-stream separator) carries an "html" fragment; each
    /// `.search-up` card carries its author id + liveId in
    /// data-up-exposure-log, its name in the avatar img's alt, and
    /// its follower count in .info__danmaku-count. Cards that do not
    /// parse are skipped, never fatal. Testable without the network.
    static func rooms(fromSearchBody body: String) -> [LiveRoom] {
        let separator = "/*<!-- fetch-stream -->*/"
        let head = body.components(separatedBy: separator).first ?? body
        guard let headData = head.data(using: .utf8),
              let json = JSONValue.parse(headData),
              let html = json["html"].stringValue, !html.isEmpty else { return [] }
        var out: [LiveRoom] = []
        let cards = html.components(separatedBy: "search-up\" data-up-exposure-log='")
        for card in cards.dropFirst() {
            guard let room = room(fromSearchCard: card) else { continue }
            out.append(room)
        }
        return out
    }

    static func room(fromSearchCard card: String) -> LiveRoom? {
        // data-up-exposure-log='{"up_id":3864168,"is_on_live":""}'
        // (single-quoted JSON; the log ends at the closing "}').
        guard let logEnd = card.range(of: "}'") else { return nil }
        let logJSON = String(card[..<logEnd.lowerBound]) + "}"
        guard let logData = logJSON.data(using: .utf8),
              let log = JSONValue.parse(logData),
              let authorID = log["up_id"].stringValue, !authorID.isEmpty,
              authorID.allSatisfy(\.isNumber) else { return nil }
        let liveID = log["is_on_live"].stringValue ?? ""
        // <img class="up__avatar …" src="…" alt="<name>"/>
        guard let imgRange = card.range(of: "up__avatar"),
              let src = Self.attribute("src", after: imgRange.upperBound, in: card),
              let name = Self.attribute("alt", after: imgRange.upperBound, in: card),
              !name.isEmpty else { return nil }
        var followers = 0
        if let countRange = card.range(of: "info__danmaku-count\">") {
            let tail = String(card[countRange.upperBound...])
            let digits = tail.prefix(while: { $0.isNumber || $0 == "." || $0 == "," })
            // wzgrx _followers: "1.2万粉丝" / "1.2亿粉丝" — a Double
            // prefix times 10,000 for 万, 100,000,000 for 亿.
            let number = Double(digits.replacingOccurrences(of: ",", with: "")) ?? 0
            let rest = String(tail.dropFirst(digits.count))
            if rest.hasPrefix("万") {
                followers = Int(number * 10_000)
            } else if rest.hasPrefix("亿") {
                followers = Int(number * 100_000_000)
            } else {
                followers = Int(number)
            }
        }
        return LiveRoom(
            id: "acfun-\(authorID)",
            platform: .acfun,
            roomID: authorID,
            title: "",
            anchorName: name,
            anchorAvatarURL: Self.imageURL(src),
            coverURL: nil,
            categoryName: nil,
            viewerCount: followers,
            isLive: !liveID.isEmpty
        )
    }

    /// value of attr="…" in the first tag at or after `start`.
    static func attribute(_ name: String, after start: String.Index, in text: String) -> String? {
        let tail = text[start...]
        guard let range = tail.range(of: "\(name)=\"") else { return nil }
        let valueStart = range.upperBound
        guard let end = tail[valueStart...].firstIndex(of: "\"") else { return nil }
        let value = String(tail[valueStart..<end])
        return value.isEmpty ? nil : value
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let json = try await http.getJSON("\(Self.origin)/api/live/info?authorId=\(roomID)", headers: Self.playHeaders)
        guard let room = Self.room(fromRoomInfo: json, fallbackID: roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return room
    }

    /// Pure parser for /api/live/info (and for directory items,
    /// which carry the same shape). Returns nil when the envelope
    /// is not a successful, identity-complete response. A paid
    /// room (paidShowUuid non-empty) is reported as not live —
    /// anonymous viewers cannot watch it.
    /// Testable without the network.
    static func room(fromRoomInfo data: JSONValue, fallbackID: String) -> LiveRoom? {
        guard data["result"].intValue == 0 else { return nil }
        let user = data["user"]
        guard let authorID = data["authorId"].stringValue, !authorID.isEmpty,
              user["id"].stringValue == authorID,
              let name = user["name"].stringValue, !name.isEmpty else { return nil }
        let liveID = data["liveId"].stringValue ?? ""
        let isPaid = !(data["paidShowUuid"].stringValue ?? "").isEmpty
        return LiveRoom(
            id: "acfun-\(authorID)",
            platform: .acfun,
            roomID: authorID,
            title: data["title"].stringValue ?? "",
            anchorName: name,
            anchorAvatarURL: Self.imageURL(user["headUrl"].stringValue),
            coverURL: Self.imageURL(data["coverUrls"][0].stringValue),
            categoryName: data["type"]["name"].stringValue,
            viewerCount: data["onlineCount"].intValue ?? 0,
            isLive: !liveID.isEmpty && !isPaid
        )
    }

    /// Pure parser for a directory liveList item (same shape as
    /// room info, plus result 0). Paid rooms are skipped (nil).
    /// Testable without the network.
    static func room(fromDirectoryItem item: JSONValue) -> LiveRoom? {
        guard let authorID = item["authorId"].stringValue, !authorID.isEmpty else { return nil }
        var info = item
        // Directory items carry no top-level "result"; the parser
        // above requires result == 0, so synthesize it.
        if info["result"].isNull {
            info = JSONValue.object(info.objectValue.merging(["result": .number(0)]) { _, new in new })
        }
        guard let room = room(fromRoomInfo: info, fallbackID: authorID) else { return nil }
        // Directory items never carry a paidShowUuid; a paid flag on
        // the item itself still excludes it.
        if !(item["paidShowUuid"].stringValue ?? "").isEmpty { return nil }
        return room
    }

    // MARK: - Play URLs (visitor login + startPlay)

    /// Anonymous visitor session (not an account login): a random
    /// did + the visitor token, cached in memory for 5 minutes
    /// (Pure Live's _VisitorSession).
    struct VisitorSession {
        let did: String
        let userID: String
        let token: String
        let security: String
        let expiresAt: Date
    }

    nonisolated(unsafe) private static var visitorSession: VisitorSession?

    private static func visitorSessionNow() async throws -> VisitorSession {
        if let cached = visitorSession, Date() < cached.expiresAt { return cached }
        let session = try await visitorLogin()
        visitorSession = session
        return session
    }

    private static func visitorLogin() async throws -> VisitorSession {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let did = "web_" + (0..<16).map { _ in String(alphabet.randomElement()!) }.joined()
        let json = try await HTTPClient.shared.postFormJSON(
            "https://id.app.acfun.cn/rest/app/visitor/login",
            fields: ["sid": "acfun.api.visitor"],
            headers: Self.playHeaders.merging(["Cookie": "_did=\(did);"]) { _, new in new }
        )
        guard json["result"].intValue == 0,
              let userID = json["userId"].stringValue, !userID.isEmpty,
              // wzgrx visitor(): the userId must match the author-id
              // pattern (positive decimal, at most 20 digits).
              userID.range(of: #"^[1-9][0-9]{0,19}$"#, options: .regularExpression) != nil,
              let token = json["acfun.api.visitor_st"].stringValue, !token.isEmpty else {
            throw LiveSiteError.invalidResponse
        }
        return VisitorSession(
            did: did,
            userID: userID,
            token: token,
            security: json["acSecurity"].stringValue ?? "",
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
    }

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let detail = try await roomDetail(roomID: room.roomID)
        guard detail.isLive else { return [] }
        do {
            return try await startPlay(authorID: room.roomID)
        } catch {
            // wzgrx _startPlay: only a RiskControl failure (here:
            // invalidResponse) is retried once with a new session.
            // A closed or paid room throws .message and is not
            // retried — retrying it would burn another login +
            // startPlay for nothing.
            guard case LiveSiteError.invalidResponse = error else { throw error }
            Self.visitorSession = nil
            return try await startPlay(authorID: room.roomID)
        }
    }

    private func startPlay(authorID: String) async throws -> [PlayStream] {
        let session = try await Self.visitorSessionNow()
        var components = URLComponents(string: "https://api.kuaishouzt.com/rest/zt/live/web/startPlay")!
        components.queryItems = [
            URLQueryItem(name: "subBiz", value: "mainApp"),
            URLQueryItem(name: "kpn", value: "ACFUN_APP"),
            URLQueryItem(name: "kpf", value: "PC_WEB"),
            URLQueryItem(name: "userId", value: session.userID),
            URLQueryItem(name: "did", value: session.did),
            URLQueryItem(name: "acfun.api.visitor_st", value: session.token),
        ]
        guard let url = components.url else { throw LiveSiteError.invalidResponse }
        let json = try await http.postFormJSON(
            url.absoluteString,
            fields: ["authorId": authorID, "pullStreamType": "FLV"],
            headers: Self.playHeaders
        )
        guard json["result"].intValue == 1 else {
            // wzgrx startPlay(): 129004 is a closed room, 380205 a
            // paid show — both are final, not retried; anything else
            // is RiskControl, retried once with a new session.
            let code = json["result"].intValue ?? -1
            if code == 129004 { throw LiveSiteError.message("直播已关播") }
            if code == 380205 { throw LiveSiteError.message("付费演出，需购票后观看") }
            Self.visitorSession = nil
            throw LiveSiteError.invalidResponse
        }
        return Self.streams(fromStartPlayJSON: json["data"], roomID: authorID)
    }

    /// Pure builder for a startPlay `data` object: one PlayStream
    /// per representation, grouped into qualities by qualityType.
    /// `videoPlayRes` is normally an object; a string-encoded copy
    /// is parsed too. Testable without the network.
    static func streams(fromStartPlayJSON data: JSONValue, roomID: String) -> [PlayStream] {
        let videoPlayRes: JSONValue
        if let encoded = data["videoPlayRes"].stringValue,
           let parsedData = encoded.data(using: .utf8),
           let parsed = JSONValue.parse(parsedData) {
            videoPlayRes = parsed
        } else {
            videoPlayRes = data["videoPlayRes"]
        }
        var qualities: [(id: String, label: String, rank: Int, urls: [(url: String, line: String)])] = []
        for manifest in videoPlayRes["liveAdaptiveManifest"].arrayValue {
            for rep in manifest["adaptationSet"]["representation"].arrayValue {
                guard rep["hidden"].boolValue != true,
                      let urlString = rep["url"].stringValue, !urlString.isEmpty,
                      let url = URL(string: urlString),
                      url.scheme == "http" || url.scheme == "https" else { continue }
                let type = rep["qualityType"].stringValue ?? ""
                let id = !type.isEmpty ? type : "id:\(rep["id"].stringValue ?? "")"
                guard !id.isEmpty else { continue }
                let label: String
                if let name = rep["name"].stringValue, !name.isEmpty {
                    label = name
                } else {
                    label = qualityLabels[type] ?? "画质 \(id)"
                }
                let level = rep["level"].intValue
                let rank: Int
                if let level, level >= 0 {
                    rank = 1_000_000 + min(level, 999_999)
                } else {
                    rank = min(max(rep["bitrate"].intValue ?? 0, 0), 999_999)
                }
                let line = url.host ?? "主线路"
                if let index = qualities.firstIndex(where: { $0.id == id }) {
                    qualities[index].urls.append((url: urlString, line: line))
                    qualities[index].rank = max(qualities[index].rank, rank)
                } else {
                    qualities.append((id: id, label: label, rank: rank, urls: [(url: urlString, line: line)]))
                }
            }
        }
        qualities.sort { $0.rank > $1.rank }
        // wzgrx mediaHeaders: UA + Referer + Origin
        // https://live.acfun.cn.
        let headers: [String: String] = [
            "user-agent": PlaybackHeaders.desktopUA,
            "origin": origin,
            "referer": "\(origin)/",
        ]
        var streams: [PlayStream] = []
        for quality in qualities {
            for entry in quality.urls {
                guard let url = URL(string: entry.url) else { continue }
                streams.append(PlayStream(url: url, quality: quality.label, line: entry.line, headers: headers, expiresAt: Self.expiry(of: url)))
            }
        }
        return streams
    }

    /// wzgrx lease(): the first field of the URL's `auth_key` query
    /// is the expiry Unix seconds (about 30 days after issue).
    static func expiry(of url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let authKey = components.queryItems?.first(where: { $0.name == "auth_key" })?.value,
              let first = authKey.split(separator: "-").first,
              let seconds = Double(String(first)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
