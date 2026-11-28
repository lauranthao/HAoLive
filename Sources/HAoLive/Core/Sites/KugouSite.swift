// KugouSite.swift
// HAo Live — 酷狗直播 (fanxing.kugou.com) adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   categories GET fanxing.kugou.com/ homepage HTML, regex
//           href=".../pcindex/category/(\d+)" + title; falls back
//           to the built-in list below when the scrape finds nothing.
//   list    GET fx1.service.kugou.com/mfanxing-home/h5/cdn/room/
//           index/list (recommend, no cid) or .../list_v4 (category,
//           cid=) with the common params (pid=0, kugouId=0,
//           platform=7, appid=1010, ...); -> {code: 0, data:
//           {hasNextPage, list: [{roomId, userId, kugouId, nickName,
//           label/topicContent/performContent, userLogo, imgPath,
//           viewerNum, fansCount, hot, liveStatus}]}} (verified:
//           200, 51 rows, hasNextPage 1).
//   search  GET fx1.service.kugou.com/pt_search/pcsearch/v1/
//           type_all.jsonp?keywords=&nums=200,0,0,0&callback=
//           pureLive{µs} — JSONP, strip callback(...) first; take
//           data.anchor.list[].
//   detail  GET service2.fanxing.kugou.com/roomcen/room/web/cdn/
//           getEnterRoomInfo?roomId= -> {code: 0, data:
//           {normalRoomInfo: {nickName, userLogo, imgPath, fansCount},
//           liveType (-1 = offline), liveSessionId (non-empty =
//           live)}} (verified: 200, liveType 0 + session).
//   play    GET fx1.service.kugou.com/video/pc/live/pull/mutiline/
//           streamaddr?std_rid=&std_plat=7&std_kid=0&streamType=
//           1-2-4-5-8&ua=fx-flash&targetLiveTypes=1-5-6&version=1000
//           &supportEncryptMode=1&appid=1010&_=ms -> {code: 0, data:
//           {roomId, status: 1, lines: [{streamProfiles: [{rate,
//           codec, layout, httpsFlv[], httpsHls[]}]}]}}; each URL is
//           validated (host liveplay.live.kugou.com, /live/ path,
//           txSecret + txTime present, token starts "0-{roomId}-")
//           and kept verbatim — signed query params are never
//           rebuilt. Verified: 200, 2 lines, FLV profiles (rate 5).
//           Quality label is "{HLS|FLV} {rate}" (the platform's own
//           rate tier); expiresAt comes from the txTime hex seconds.
// Danmaku: NOT implemented — the reference chat channel is a binary
// protobuf protocol whose dispatch request is signed with a fixed
// salt, and the frame codec needs a Snappy decoder; copying the
// salt would break the no-copied-keys rule, so danmakuStream stays
// the default empty implementation.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class KugouSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .kugoulive
    private let http = HTTPClient.shared

    private static let webBase = "https://fanxing.kugou.com"
    private static let apiBase = "https://fx1.service.kugou.com"
    private static let detailBase = "https://service2.fanxing.kugou.com"
    private static let pageSize = 30

    private static var headers: [String: String] {
        ["Origin": webBase, "Referer": "\(webBase)/"]
    }

    /// Built-in categories when the homepage scrape finds none.
    static let fallbackCategories: [(id: String, name: String)] = [
        ("8000", "推荐"), ("100001", "一起玩"), ("100002", "音乐"),
        ("31050", "高清"), ("7024", "舞蹈"), ("1009", "颜值"),
        ("1001", "新秀"), ("3007", "酷次元"), ("7041", "搞笑"),
        ("31", "国风"), ("6201", "游戏女神"), ("6007", "王者荣耀"),
        ("6004", "和平精英"), ("6003", "网游竞技"),
    ]

    /// Category ids that are personal routes, not browse categories.
    private static let personalCategoryIDs: Set<String> = ["3001", "3009", "3014", "3015"]

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        if let html = try? await http.get(Self.webBase + "/", headers: Self.headers),
           let text = String(data: html, encoding: .utf8) {
            let found = Self.categories(fromHomepageHTML: text)
            if !found.isEmpty { return found }
        }
        return Self.fallbackCategories.map {
            LiveCategory(id: "kugoulive-\($0.id)", platform: .kugoulive, name: $0.name, iconName: nil, iconURL: nil)
        }
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await directory(page: 1, categoryID: "8000")
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await directory(page: page, categoryID: "8000")
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await directory(page: 1, categoryID: Self.categoryID(of: category))
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await directory(page: page, categoryID: Self.categoryID(of: category))
    }

    private func directory(page: Int, categoryID: String) async throws -> [LiveRoom] {
        guard page >= 1, page <= 10_000 else { return [] }
        let recommend = categoryID == "8000"
        let path = recommend ? "/mfanxing-home/h5/cdn/room/index/list" : "/mfanxing-home/h5/cdn/room/index/list_v4"
        var params: [(String, String)] = [
            ("pid", "0"), ("kugouId", "0"), ("doubleLiveFirst", "1"),
            ("sysVersion", "0"), ("platform", "7"), ("device", "PureLive-Web"),
            ("channel", "0"), ("version", "99999"), ("longitude", "0"),
            ("latitude", "0"), ("appid", "1010"), ("liveTypeFilter", "0"),
            ("isNew", "0"), ("entranceType", "0"), ("uiMode", "0"),
            ("page", "\(page)"),
        ]
        if !recommend { params.append(("cid", categoryID)) }
        let json = try await http.getJSON(Self.urlWithQuery("\(Self.apiBase)\(path)", params), headers: Self.headers)
        let data = try Self.responseData(json)
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for entry in data["list"].arrayValue {
            let raw = entry["uiType"].stringValue == "star" ? entry["data"] : entry
            guard let room = Self.room(fromListItem: raw), room.isLive, seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
        }
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

    /// One JSONP call returns up to 200 anchors; pages slice locally.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100, page >= 1, page <= 100 else { return [] }
        // A bare room id goes straight to detail.
        if Self.validRoomID(query) != nil, page == 1 {
            if let detail = try? await roomDetail(roomID: query) {
                return [detail]
            }
            return []
        }
        let callback = "pureLive\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        let url = Self.urlWithQuery("\(Self.apiBase)/pt_search/pcsearch/v1/type_all.jsonp", [
            ("keywords", query), ("nums", "200,0,0,0"), ("callback", callback),
        ])
        guard let data = try? await http.get(url, headers: Self.headers),
              let text = String(data: data, encoding: .utf8),
              let json = Self.parseJSONP(text, callback: callback) else {
            throw LiveSiteError.invalidResponse
        }
        let code = json["status"].intValue ?? json["code"].intValue ?? 0
        guard code == 0 || code == 1 else { throw LiveSiteError.invalidResponse }
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for item in json["data"]["anchor"]["list"].arrayValue {
            guard let room = Self.room(fromListItem: item), seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
        }
        let start = (page - 1) * Self.pageSize
        guard start < rooms.count else { return [] }
        return Array(rooms[start..<min(rooms.count, start + Self.pageSize)])
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let id = Self.validRoomID(roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let json = try await http.getJSON(Self.urlWithQuery("\(Self.detailBase)/roomcen/room/web/cdn/getEnterRoomInfo", [("roomId", id)]), headers: Self.headers)
        let data = try Self.responseData(json)
        return try Self.room(fromDetailData: data, roomID: id)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let id = Self.validRoomID(room.roomID) else { return [] }
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let url = Self.urlWithQuery("\(Self.apiBase)/video/pc/live/pull/mutiline/streamaddr", [
            ("std_rid", id), ("std_plat", "7"), ("std_kid", "0"),
            ("streamType", "1-2-4-5-8"), ("ua", "fx-flash"),
            ("targetLiveTypes", "1-5-6"), ("version", "1000"),
            ("supportEncryptMode", "1"), ("appid", "1010"), ("_", "\(millis)"),
        ])
        let json = try await http.getJSON(url, headers: Self.headers)
        let data = try Self.responseData(json)
        guard data["roomId"].stringValue == id, data["status"].intValue == 1 else { return [] }
        var variants: [(id: String, protocol: String, rate: Int, urls: [URL])] = []
        var indexByID: [String: Int] = [:]
        for line in data["lines"].arrayValue {
            for profile in line["streamProfiles"].arrayValue {
                let rate = profile["rate"].intValue ?? 0
                let codec = profile["codec"].intValue ?? 0
                let layout = profile["layout"].intValue ?? 0
                for (field, proto) in [("httpsFlv", "flv"), ("httpsHls", "hls")] {
                    let variantID = "\(proto):\(rate):\(codec):\(layout)"
                    for raw in profile[field].arrayValue {
                        guard let rawString = raw.stringValue,
                              let uri = Self.validMediaURL(rawString, roomID: id, protocol: proto) else { continue }
                        if let index = indexByID[variantID] {
                            if !variants[index].urls.contains(uri) { variants[index].urls.append(uri) }
                        } else {
                            indexByID[variantID] = variants.count
                            variants.append((id: variantID, protocol: proto, rate: rate, urls: [uri]))
                        }
                    }
                }
            }
        }
        variants.sort { $0.rate > $1.rate }
        let headers = PlaybackHeaders.headers(platform: .kugoulive, roomID: id)
        var streams: [PlayStream] = []
        for variant in variants {
            for (lineIndex, url) in variant.urls.enumerated() {
                streams.append(PlayStream(
                    url: url,
                    quality: "\(variant.protocol.uppercased()) \(variant.rate)",
                    line: "线路\(lineIndex + 1)",
                    headers: headers,
                    expiresAt: Self.expiry(of: url)
                ))
            }
        }
        return streams
    }

    // MARK: - Pure parsers

    /// Room ids are 3–11 digits, first digit non-zero.
    static func validRoomID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, value.count <= 11,
              value.first.map({ $0 != "0" }) == true,
              value.allSatisfy({ $0.isNumber }) else { return nil }
        return value
    }

    static func categoryID(of category: LiveCategory) -> String {
        let id = category.id.hasPrefix("kugoulive-") ? String(category.id.dropFirst("kugoulive-".count)) : category.id
        return id.isEmpty ? "8000" : id
    }

    /// code must be 0 and data must be a non-empty object.
    static func responseData(_ json: JSONValue) throws -> JSONValue {
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        let data = json["data"]
        guard !data.isNull else { throw LiveSiteError.invalidResponse }
        return data
    }

    /// Categories from the fanxing homepage HTML. Falls back to []
    /// (the caller substitutes the built-in list).
    static func categories(fromHomepageHTML html: String) -> [LiveCategory] {
        let pattern = #"href=["'](?:https://fanxing\.kugou\.com)?/pcindex/category/(\d{1,8})[^"']*["'][^>]*title=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        var out: [LiveCategory] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html) else { continue }
            let id = String(html[idRange])
            let name = Self.decodeHTMLEntities(String(html[nameRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !personalCategoryIDs.contains(id), !name.isEmpty, seen.insert(id).inserted else { continue }
            out.append(LiveCategory(id: "kugoulive-\(id)", platform: .kugoulive, name: name, iconName: nil, iconURL: nil))
        }
        return out
    }

    static func decodeHTMLEntities(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Strip the `callback(...)` wrapper of a JSONP body; nil when
    /// the wrapper is malformed or names a different callback.
    static func parseJSONP(_ text: String, callback: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"), close > open else { return nil }
        let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == callback else { return nil }
        let tail = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ";", with: "")
        guard tail.isEmpty else { return nil }
        let inner = String(trimmed[trimmed.index(after: open)..<close])
        guard let data = inner.data(using: .utf8) else { return nil }
        return JSONValue.parse(data)
    }

    /// Pure parser for a list / search card. Nil when the room id is
    /// invalid. Offline anchors are kept (isLive false) — only the
    /// recommend/category lists filter them out.
    static func room(fromListItem item: JSONValue) -> LiveRoom? {
        guard let roomID = validRoomID(item["roomId"].stringValue ?? "") else { return nil }
        let flag = item["liveStatus"].intValue ?? item["status"].intValue ?? item["liveType"].intValue
        let isLive = flag == nil ? true : flag! > 0
        let nick = item["nickName"].stringValue ?? ""
        let title = HaoText.firstNonEmpty(
            item["label"].stringValue, item["topicContent"].stringValue,
            item["performContent"].stringValue, nick.isEmpty ? nil : nick
        ) ?? "酷狗直播"
        return LiveRoom(
            id: "kugoulive-\(roomID)",
            platform: .kugoulive,
            roomID: roomID,
            title: title,
            anchorName: nick.isEmpty ? "酷狗直播" : nick,
            anchorAvatarURL: Self.imageURL(HaoText.firstNonEmpty(item["userLogo"].stringValue, item["logo"].stringValue)),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(item["imgPath"].stringValue, item["imagePath"].stringValue)),
            categoryName: item["category"][0]["name"].stringValue,
            viewerCount: item["viewerNum"].intValue ?? item["getViewerNum"].intValue ?? 0,
            isLive: isLive
        )
    }

    /// Pure parser for the getEnterRoomInfo payload.
    static func room(fromDetailData data: JSONValue, roomID: String) throws -> LiveRoom {
        let normal = data["normalRoomInfo"]
        guard !normal.isNull,
              !(normal["nickName"].stringValue ?? "").isEmpty || !(normal["kugouId"].stringValue ?? "").isEmpty else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let liveType = data["liveType"].intValue
        let session = data["liveSessionId"].stringValue ?? ""
        let isLive: Bool
        if liveType == -1 {
            isLive = false
        } else if !session.isEmpty {
            isLive = true
        } else {
            isLive = false
        }
        let nick = normal["nickName"].stringValue ?? ""
        return LiveRoom(
            id: "kugoulive-\(roomID)",
            platform: .kugoulive,
            roomID: roomID,
            title: nick.isEmpty ? "酷狗直播" : nick,
            anchorName: nick.isEmpty ? "酷狗直播" : nick,
            anchorAvatarURL: Self.imageURL(normal["userLogo"].stringValue),
            coverURL: Self.imageURL(normal["imgPath"].stringValue),
            categoryName: nil,
            viewerCount: 0,
            isLive: isLive
        )
    }

    /// Validate one signed media URL (kept verbatim when valid):
    /// https, liveplay.live.kugou.com host, /live/ path, matching
    /// extension, txSecret + txTime present, token bound to the room.
    static func validMediaURL(_ raw: String, roomID: String, protocol proto: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(),
              host == "liveplay.live.kugou.com" || host.hasSuffix(".liveplay.live.kugou.com"),
              url.path.hasPrefix("/live/"),
              url.path.lowercased().hasSuffix(proto == "hls" ? ".m3u8" : ".flv"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, query[item.name] == nil {
                query[item.name] = value
            }
        }
        guard let secret = query["txSecret"], !secret.isEmpty,
              let txTime = query["txTime"], Self.isHex(txTime, minLength: 8, maxLength: 16),
              let token = query["token"], token.hasPrefix("0-\(roomID)-") else { return nil }
        return url
    }

    static func isHex(_ value: String, minLength: Int, maxLength: Int) -> Bool {
        value.count >= minLength && value.count <= maxLength &&
            value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }

    /// txTime is hex seconds since epoch: the URL's expiry.
    static func expiry(of url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let txTime = components.queryItems?.first(where: { $0.name == "txTime" })?.value,
              let seconds = Int(txTime, radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Build a URL with percent-encoded query items.
    static func urlWithQuery(_ base: String, _ params: [(String, String)]) -> String {
        guard var components = URLComponents(string: base) else { return base }
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.string ?? base
    }
}
