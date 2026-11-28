// DouyinSite.swift
// HAo Live — real Douyin adapter (anonymous, no login).
// Follows Pure Live's Douyin route (lib/shared/platforms/douyin):
//   * anonymous cookie first — GET https://live.douyin.com/?from_nav=1,
//     keep the ttwid / UIFID_TEMP pairs from set-cookie, send them back
//     as a Cookie header on every Douyin request (single-flight fetch,
//     cached for the process);
//   * headers on every request — Authority live.douyin.com, Referer
//     https://live.douyin.com, the Chrome/134 desktop UA;
//   * categories from the home page's {"pathname":"/","categoryData":}
//     blob (brace-matched + unescaped); ids are "{id_str},{type}" and
//     sub-partitions become their own flat categories;
//   * recommend via GET /webcast/feed/ (aid=6383, app_name=douyin_web,
//     need_map=1, is_draw=1, enter_source/source_key =
//     web_homepage_hot_web_live_card) — no signature; the response is
//     parsed tolerantly (legacy data.data list OR the post-Aug-2026
//     list of envelopes with the room JSON embedded as a string);
//   * category rooms via GET /webcast/web/partition/detail/room/v2/
//     with the full browser params, signed with a_bogus (see
//     DouyinABogus.swift); 15 rooms per page, offset = (page-1)*15.
//   * room page + streams + danmaku as before (roomStore.roomInfo on
//     the room page; web_stream_url live_core_sdk_data / legacy maps;
//     WS + protobuf PushFrame; the WS room_id is the room's id_str).
// Verified live from this VM 2026-11-26 (room page path only):
//   room page GET https://live.douyin.com/{web_rid} — the page embeds
//   an escaped JSON blob (Next.js RSC payload) containing:
//     homeStore.recommendCategoryData: [{partition: {id_str, title},
//       has_parent_node, second_node, first_node}] — the category list
//     roomStore.roomInfo: {room: {id_str, status (2 = live, 4 = ended),
//       title, user_count_str}, web_rid, anchor: {nickname,
//       avatar_thumb: {url_list}}, web_stream_url: {...} | null}
//   Stream URLs — Pure Live's route (the room probed 2026-11-27 was
//   offline, so web_stream_url was null and no live room's stream
//   keys could be verified from this VM; needs a device):
//     modern: web_stream_url.live_core_sdk_data.pull_data.stream_data
//       (a JSON string; data: {qualityKey: {main: {flv, hls}}})
//     legacy: web_stream_url.flv_pull_url / .hls_pull_url_map
//       (qualityKey -> URL string or {url_list: [...]})
//   Quality keys are joined by key, never by position; "ao" is
//   audio-only and is skipped. Per quality the URLs keep Pure
//   Live's order — FLV first, then HLS — and mpv plays both.
//   Quality keys: FULL_HD1 原画, HD1 超清, SD1 高清, SD2 标清.
// NOT verifiable from this VM — the webcast JSON APIs all refuse
// this egress IP (feed: "url doesn't match", enter: empty reply,
// room list: 404), so recommend / category rooms / search call those
// APIs and return what they get (usually nothing here). They need a
// China-network device to confirm. The room page path above is the
// part that is verified: opening a known room id works end to end.
// Danmaku: WebSocket + protobuf PushFrame (see DouyinDanmaku); the WS
// room_id is the room's id_str, resolved from the room page.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DouyinSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .douyin
    private let http = HTTPClient.shared

    private static let webBase = "https://live.douyin.com"

    /// Pull-URL quality key -> display name.
    private static let qualityNames: [String: String] = [
        "FULL_HD1": "原画", "HD1": "超清", "SD1": "高清", "SD2": "标清",
    ]

    /// Room info cache (Pure Live parses the stream from the ROOM
    /// object the controller already fetched — roomInfo is not
    /// re-fetched for every playURLs call). roomDetail stores it,
    /// playURLs reuses it for 60 s; the stream URLs inside are
    /// short-lived, so the TTL stays short.
    private static let roomInfoCacheLock = NSLock()
    nonisolated(unsafe) private static var roomInfoCache: [String: (info: JSONValue, at: Date)] = [:]

    private static func cachedRoomInfo(for roomID: String) -> JSONValue? {
        roomInfoCacheLock.lock()
        defer { roomInfoCacheLock.unlock() }
        guard let entry = roomInfoCache[roomID],
              Date().timeIntervalSince(entry.at) < 60 else { return nil }
        return entry.info
    }

    private static func storeRoomInfo(_ info: JSONValue, for roomID: String) {
        roomInfoCacheLock.lock()
        defer { roomInfoCacheLock.unlock() }
        roomInfoCache[roomID] = (info, Date())
    }

    // MARK: - Lists

    /// Browser-style headers for every Douyin request (Pure Live's
    /// getRequestHeaders minus the cookie, which requestHeaders adds).
    private static let baseHeaders: [String: String] = [
        "Authority": "live.douyin.com",
        "Referer": "https://live.douyin.com",
        "User-Agent": ABogus.defaultUserAgent,
    ]

    /// Anonymous cookie for the process ("ttwid=...; UIFID_TEMP=..."),
    /// fetched once (single-flight) from the home page's set-cookie.
    /// Pure Live keeps the same static; a user-supplied cookie (the
    /// settings cookie field) is out of scope here — HAo Live has no
    /// Douyin login, and the anonymous cookie is what the web client
    /// uses for these endpoints.
    /// Single-flight lazy cache: two concurrent callers may both
    /// fetch once, both writing the same value — benign. Same
    /// nonisolated(unsafe) shape as HuyaSite's static UID caches.
    private nonisolated(unsafe) static var anonymousCookie = ""
    private nonisolated(unsafe) static var anonymousCookieTask: Task<String, Never>?

    /// Headers for Douyin API calls: base headers + anonymous cookie
    /// when one has been fetched. An empty cookie still returns the
    /// base headers — the endpoints answer without it sometimes, and
    /// a missing cookie must not block the request.
    static func requestHeaders() async -> [String: String] {
        var headers = baseHeaders
        let cookie = await anonymousCookieValue()
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    private static func anonymousCookieValue() async -> String {
        if !anonymousCookie.isEmpty { return anonymousCookie }
        let task = anonymousCookieTask ?? Task { await fetchAnonymousCookie() }
        anonymousCookieTask = task
        let value = await task.value
        anonymousCookieTask = nil
        if !value.isEmpty { anonymousCookie = value }
        return value
    }

    /// GET the home page and keep the ttwid / UIFID_TEMP pairs from
    /// set-cookie. Testable without the network via
    /// cookiePairs(fromSetCookie:).
    private static func fetchAnonymousCookie() async -> String {
        guard let (_, headers) = try? await HTTPClient.shared.getWithHeaders(
            "\(webBase)/?from_nav=1", headers: baseHeaders),
            let setCookie = headers["set-cookie"] else { return "" }
        return cookiePairs(fromSetCookie: setCookie).joined(separator: "; ")
    }

    /// Pull "ttwid=..." / "UIFID_TEMP=..." pairs out of a (possibly
    /// comma-joined) set-cookie value. The scan reads up to the next
    /// ';', so Expires dates (which contain commas) stay intact.
    static func cookiePairs(fromSetCookie setCookie: String) -> [String] {
        var pairs: [String] = []
        for name in ["ttwid=", "UIFID_TEMP="] {
            guard let range = setCookie.range(of: name) else { continue }
            let rest = setCookie[range.upperBound...]
            let value = rest.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            if !value.isEmpty { pairs.append("\(name)\(value)") }
        }
        return pairs
    }

    func categories() async throws -> [LiveCategory] {
        let html = try await pageHTML(path: "?from_nav=1", headers: await Self.requestHeaders())
        if let data = Self.extractCategoryData(from: html) {
            let categories = Self.categories(fromCategoryData: data)
            if !categories.isEmpty { return categories }
        }
        // Fallback: the older homeStore.recommendCategoryData blob.
        guard let homeStore = Self.extractEscapedObject(marker: "homeStore", in: html) else {
            return []
        }
        return Self.categories(fromHomeStore: homeStore)
    }

    /// Pure parser for the {"pathname":"/","categoryData": [...]}
    /// blob Pure Live reads from the home page. Sub-partitions become
    /// their own flat categories (HAo Live's LiveCategory has no
    /// children); ids are "douyin-{id_str},{type}".
    /// Testable without the network.
    static func categories(fromCategoryData data: JSONValue) -> [LiveCategory] {
        var out: [LiveCategory] = []
        for item in data["categoryData"].arrayValue {
            let partition = item["partition"]
            guard let id = partition["id_str"].stringValue,
                  let type = partition["type"].stringValue,
                  let title = partition["title"].stringValue, !title.isEmpty else { continue }
            out.append(LiveCategory(id: "douyin-\(id),\(type)", platform: .douyin, name: title, iconName: nil))
            for sub in item["sub_partition"].arrayValue {
                let subPartition = sub["partition"]
                guard let subID = subPartition["id_str"].stringValue,
                      let subType = subPartition["type"].stringValue,
                      let subTitle = subPartition["title"].stringValue, !subTitle.isEmpty else { continue }
                out.append(LiveCategory(id: "douyin-\(subID),\(subType)", platform: .douyin, name: subTitle, iconName: nil))
            }
        }
        return out
    }

    /// Pure parser for homeStore.recommendCategoryData — the fallback
    /// when the categoryData blob is absent from the home page.
    /// Testable without the network.
    static func categories(fromHomeStore homeStore: JSONValue) -> [LiveCategory] {
        homeStore["recommendCategoryData"].arrayValue.compactMap { item in
            let partition = item["partition"]
            guard let id = partition["id_str"].stringValue,
                  let title = partition["title"].stringValue, !title.isEmpty else { return nil }
            return LiveCategory(id: "douyin-\(id)", platform: .douyin, name: title, iconName: nil)
        }
    }

    /// Extract the {"pathname":"/","categoryData": [...]} object from
    /// the home page HTML. The blob is backslash-escaped once (quotes
    /// appear as \"), so the scan is the escaped-quote-aware one from
    /// HaoText, starting at the marker's own "{" (the marker IS the
    /// start of the object — unlike extractEscapedJSONObject, which
    /// looks for the first "{" AFTER its marker).
    /// Testable without the network.
    static func extractCategoryData(from html: String) -> JSONValue? {
        let marker = #"{\"pathname\":\"/\",\"categoryData\":"#
        guard let markerRange = html.range(of: marker) else { return nil }
        let openIndex = markerRange.lowerBound
        let escapedQuote = "\\\""
        let escapedBackslash = "\\\\"
        var depth = 0
        var inString = false
        var index = openIndex
        while index < html.endIndex {
            if html[index...].hasPrefix(escapedQuote) {
                inString.toggle()
                index = html.index(index, offsetBy: 2, limitedBy: html.endIndex) ?? html.endIndex
                continue
            }
            if html[index...].hasPrefix(escapedBackslash) {
                index = html.index(index, offsetBy: 2, limitedBy: html.endIndex) ?? html.endIndex
                continue
            }
            let ch = html[index]
            if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let raw = String(html[openIndex...index])
                        let unescaped = HaoText.unescapeJSONString(raw)
                        guard let data = unescaped.data(using: .utf8),
                              let json = JSONValue.parse(data) else { return nil }
                        return json
                    }
                }
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// "douyin-123,0" (new) or "douyin-123" (old homeStore ids) ->
    /// ("123", "0"). The partition id is the bare id_str; the type
    /// is "" when the category predates the type suffix.
    static func partition(from categoryID: String) -> (String, String) {
        let bare = categoryID.hasPrefix("douyin-")
            ? String(categoryID.dropFirst("douyin-".count)) : categoryID
        let parts = bare.split(separator: ",", maxSplits: 1).map(String.init)
        return (parts.first ?? bare, parts.count > 1 ? parts[1] : "")
    }

    func recommendRooms() async throws -> [LiveRoom] {
        // Pure Live's feed endpoint + params; no a_bogus signing.
        let url = "\(Self.webBase)/webcast/feed/?aid=6383&app_name=douyin_web&need_map=1&is_draw=1&inner_from_drawer=0&enter_source=web_homepage_hot_web_live_card&source_key=web_homepage_hot_web_live_card"
        guard let json = try? await http.getJSON(url, headers: await Self.requestHeaders()) else { return [] }
        return Self.rooms(fromFeed: json)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let (partition, partitionType) = Self.partition(from: category.id)
        let offset = (page - 1) * 15
        // Param order is Pure Live's map order; buildRequestUrl
        // appends compress + msToken and signs with a_bogus.
        let params: [(String, String)] = [
            ("aid", "6383"),
            ("app_name", "douyin_web"),
            ("live_id", "1"),
            ("device_platform", "web"),
            ("language", "zh-CN"),
            ("enter_from", "link_share"),
            ("cookie_enabled", "true"),
            ("screen_width", "1980"),
            ("screen_height", "1080"),
            ("browser_language", "zh-CN"),
            ("browser_platform", "Win32"),
            ("browser_name", "Edge"),
            ("browser_version", "125.0.0.0"),
            ("browser_online", "true"),
            ("count", "15"),
            ("offset", "\(offset)"),
            ("partition", partition),
            ("partition_type", partitionType),
            ("req_from", "2"),
        ]
        let url = DouyinURLSigning.signedURL(
            base: "\(Self.webBase)/webcast/web/partition/detail/room/v2/",
            params: params)
        guard let json = try? await http.getJSON(url, headers: await Self.requestHeaders()),
              json["status_code"].intValue == 0 else { return [] }
        return json["data"]["data"].arrayValue.compactMap { Self.room(fromCategoryItem: $0) }
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    /// Douyin web search: the aweme search first, then Pure Live's
    /// partition-search fallback (douyin_site.dart:377-495). The
    /// anonymous aweme search answers 2483 (login required), so
    /// without the fallback search is always 0 results.
    private func search(keyword: String) async throws -> [LiveRoom] {
        let rooms = try await searchAweme(keyword: keyword)
        if !rooms.isEmpty { return rooms }
        return try await searchByPartition(keyword: keyword)
    }

    /// Douyin web search. Unverified from this VM (the aweme search
    /// API needs a signature); parsed defensively, returns [] on failure.
    private func searchAweme(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://www.douyin.com/aweme/v1/web/search/item/?device_platform=webapp&aid=6383&keyword=\(encoded)&search_source=tab_search&count=10"
        guard let json = try? await http.getJSON(url, headers: ["Referer": "https://www.douyin.com/"]) else {
            return []
        }
        return json["aweme_list"].arrayValue.compactMap { item in
            guard item["is_live"].boolValue == true,
                  let roomID = item["room_id"].stringValue ?? item["aweme_id"].stringValue,
                  !roomID.isEmpty else { return nil }
            let author = item["author"]
            return LiveRoom(
                id: "douyin-\(roomID)",
                platform: .douyin,
                roomID: roomID,
                title: item["desc"].stringValue ?? "",
                anchorName: author["nickname"].stringValue ?? "",
                anchorAvatarURL: Self.imageURL(author["avatar_thumb"]["url_list"][0].stringValue),
                coverURL: Self.imageURL(item["video"]["cover"]["url_list"][0].stringValue),
                categoryName: nil,
                viewerCount: 0,
                isLive: true
            )
        }
    }

    /// Pure Live's _searchByPartition (douyin_site.dart:436-466):
    /// the partitions whose name matches the keyword, first 3, each
    /// contributing rooms until 10 are merged (deduped by room id).
    /// A partition that fails is skipped; an empty merge is [].
    private func searchByPartition(keyword: String) async throws -> [LiveRoom] {
        let areas = try await partitionSearch(keyword: keyword)
        var merged: [LiveRoom] = []
        var seen: Set<String> = []
        for area in areas.prefix(3) {
            let rooms = (try? await searchPartitionRooms(
                areaID: area.id, areaName: area.name, count: 10, offset: 0)) ?? []
            for room in rooms {
                guard seen.insert(room.roomID).inserted else { continue }
                merged.append(room)
                if merged.count >= 10 { return merged }
            }
        }
        return merged
    }

    /// Pure Live's _partitionSearch (douyin_site.dart:428-434): the
    /// partitions whose name matches the keyword (anonymous), as
    /// "id_str,type" ids — the same id shape categories use.
    private func partitionSearch(keyword: String) async throws -> [(id: String, name: String)] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(Self.webBase)/webcast/web/partition/search/?keyword=\(encoded)&aid=6383"
        let cookie = await Self.requestHeaders()["Cookie"] ?? ""
        guard let json = try? await http.getJSON(url, headers: Self.searchHeaders(keyword: keyword, cookie: cookie)),
              json["status_code"].intValue == 0 else { return [] }
        return json["data"]["SearchResult"].arrayValue.compactMap { item in
            let partition = item["partition"]
            guard let id = partition["id_str"].stringValue, !id.isEmpty,
                  let type = partition["type"].stringValue, !type.isEmpty else { return nil }
            return (id: "\(id),\(type)", name: partition["title"].stringValue ?? "")
        }
    }

    /// Pure Live's _searchPartitionRooms (douyin_site.dart:469-495):
    /// one matched partition's rooms — signed live.douyin.com first,
    /// then the unsigned webcast.amemv.com host when that fails or
    /// is empty. Rooms without a tag show the partition's name.
    private func searchPartitionRooms(areaID: String, areaName: String, count: Int, offset: Int) async throws -> [LiveRoom] {
        let (partition, partitionType) = Self.partition(from: "douyin-\(areaID)")
        let params = Self.searchPartitionParams(partition: partition, type: partitionType, count: count, offset: offset)
        let cookie = await Self.requestHeaders()["Cookie"] ?? ""
        let headers = Self.searchHeaders(keyword: "", cookie: cookie)
        let url = DouyinURLSigning.signedURL(
            base: "\(Self.webBase)/webcast/web/partition/detail/room/v2/",
            params: params)
        if let json = try? await http.getJSON(url, headers: headers),
           json["status_code"].intValue == 0 {
            let rooms = json["data"]["data"].arrayValue.compactMap {
                Self.room(fromCategoryItem: $0, areaName: areaName)
            }
            if !rooms.isEmpty { return rooms }
        }
        return try await amemvRooms(
            partition: partition, type: partitionType, areaName: areaName,
            count: count, offset: offset, cookie: cookie)
    }

    /// Pure Live's _amemvRooms (douyin_site.dart:276-294): the same
    /// partition room list from the unsigned backup host.
    private func amemvRooms(partition: String, type: String, areaName: String, count: Int, offset: Int, cookie: String) async throws -> [LiveRoom] {
        let params = Self.searchPartitionParams(partition: partition, type: type, count: count, offset: offset)
        let query = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let url = "https://webcast.amemv.com/webcast/web/partition/detail/room/v2/?\(query)"
        guard let json = try? await http.getJSON(url, headers: Self.searchHeaders(keyword: "", cookie: cookie)),
              json["status_code"].intValue == 0 else { return [] }
        return json["data"]["data"].arrayValue.compactMap {
            Self.room(fromCategoryItem: $0, areaName: areaName)
        }
    }

    /// Pure Live's _searchPartitionParams (douyin_site.dart:296-318)
    /// + DouyinApi.searchHeaders (douyin_api.dart:576-590).
    static func searchPartitionParams(partition: String, type: String, count: Int, offset: Int) -> [(String, String)] {
        [
            ("aid", "6383"),
            ("app_name", "douyin_web"),
            ("live_id", "1"),
            ("device_platform", "web"),
            ("language", "zh-CN"),
            ("browser_language", "zh-CN"),
            ("browser_platform", "Win32"),
            ("browser_name", "Chrome"),
            ("browser_version", "120.0.0.0"),
            ("partition", partition),
            ("partition_type", type),
            ("count", "\(count)"),
            ("offset", "\(offset)"),
            ("cookie_enabled", "true"),
            ("screen_width", "1920"),
            ("screen_height", "1080"),
        ]
    }

    /// Headers of the search requests: the web client's search page
    /// as the Referer (an empty keyword for the partition rooms).
    static func searchHeaders(keyword: String, cookie: String) -> [String: String] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        var headers: [String: String] = [
            "User-Agent": ABogus.defaultUserAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": "https://www.douyin.com/search/\(encoded)?source=switch_tab&type=live",
            "Origin": "https://www.douyin.com",
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let roomInfo = try await roomInfo(for: roomID)
        return Self.room(fromRoomInfo: roomInfo, webRID: roomID)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let roomInfo = try await roomInfo(for: room.roomID)
        // Pure Live reads the stream from the ROOM object
        // (roomStore.roomInfo.room.stream_url, douyin_site.dart:627);
        // the old web_stream_url field on roomInfo is null even when
        // the store hydrates, which is why rooms "showed but never
        // played". The legacy field stays as a fallback.
        let streamURL = roomInfo["room"]["stream_url"]
        let legacy = roomInfo["web_stream_url"]
        let stream = !streamURL.isNull ? streamURL : legacy
        guard !stream.isNull else { return [] } // offline: no stream
        // Stream requests carry the anonymous cookie too (Pure Live
        // puts headers["cookie"] on the stream data). The FLV URL
        // played without it from this VM, but the cookie is what
        // the web client sends, and some lines gate on it.
        var headers = PlaybackHeaders.headers(platform: .douyin, roomID: room.roomID)
        if let cookie = await Self.requestHeaders()["Cookie"], !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return Self.streams(fromStreamURL: stream, headers: headers)
    }

    /// Pure parser for the whole web_stream_url object (Pure Live's
    /// parseStreamQualities): the modern live_core_sdk_data.pull_data
    /// .stream_data payload (a JSON string; per quality key, main.flv
    /// + main.hls) joined by quality key with the legacy
    /// flv_pull_url / hls_pull_url_map / hls_pull_url maps. Per key
    /// the URLs keep Pure Live's order — FLV first, then HLS — so
    /// the player tries the FLV line before its HLS twin.
    /// Audio-only ("ao") keys are skipped — they carry no video track.
    /// Testable without the network.
    static func streams(fromStreamURL streamURL: JSONValue, headers: [String: String] = [:]) -> [PlayStream] {
        // Modern payload: stream_data is a JSON string
        // {"data": {qualityKey: {main: {flv, hls}}}}.
        var modern: [String: [String]] = [:]
        if let text = streamURL["live_core_sdk_data"]["pull_data"]["stream_data"].stringValue,
           let data = text.data(using: .utf8),
           let json = JSONValue.parse(data) {
            for (key, value) in json["data"].objectValue {
                var urls: [String] = []
                if let flv = value["main"]["flv"].stringValue, !flv.isEmpty { urls.append(flv) }
                if let hls = value["main"]["hls"].stringValue, !hls.isEmpty { urls.append(hls) }
                if !urls.isEmpty { modern[key.lowercased()] = urls }
            }
        }
        // Legacy maps: qualityKey -> URL string or {url_list: [...]}.
        // Pure Live reads flv_pull_url + hls_pull_url_map only —
        // there is no "hls_pull_url" key in its parser.
        var legacyFLV: [String: String] = [:]
        var legacyHLS: [String: String] = [:]
        for key in ["flv_pull_url"] {
            for (mapKey, value) in streamURL[key].objectValue {
                let urlString = value.stringValue ?? value["url_list"][0].stringValue
                if let urlString, !urlString.isEmpty {
                    legacyFLV[mapKey.lowercased()] = urlString
                }
            }
        }
        for mapKey in ["hls_pull_url_map"] {
            for (key, value) in streamURL[mapKey].objectValue {
                let urlString = value.stringValue ?? value["url_list"][0].stringValue
                if let urlString, !urlString.isEmpty {
                    legacyHLS[key.lowercased()] = urlString
                }
            }
        }
        // Display names from resolution_name (keys matched
        // case-insensitively), else the known key table, else the raw key.
        var resolutionNames: [String: String] = [:]
        for (key, value) in streamURL["resolution_name"].objectValue {
            if let name = value.stringValue, !name.isEmpty {
                resolutionNames[key.lowercased()] = name
            }
        }
        // All quality keys, joined by key (never by position).
        var keys = Array(modern.keys)
        for key in legacyFLV.keys where !keys.contains(key) { keys.append(key) }
        for key in legacyHLS.keys where !keys.contains(key) { keys.append(key) }
        // Display names + rank from
        // live_core_sdk_data.pull_data.options.qualities (Pure Live's
        // parseStreamQualities, authoritative): sdk_key -> (name,
        // level). Legacy keys map onto the modern sdk_keys — the
        // reflow payload proves origin FLV == FULL_HD1 FLV,
        // ld == SD1, sd == SD2 (identical URLs), so the same URL
        // must not appear twice under two quality buttons.
        var qualityInfo: [String: (name: String, level: Int)] = [:]
        for quality in streamURL["live_core_sdk_data"]["pull_data"]["options"]["qualities"].arrayValue {
            guard let key = quality["sdk_key"].stringValue?.lowercased(), !key.isEmpty else { continue }
            qualityInfo[key] = (quality["name"].stringValue ?? key, quality["level"].intValue ?? 0)
        }
        // Pure Live's _douyinQualityRank, verbatim: ORIGIN 6M >
        // FULL_HD1/UHD 5M > HD1/HD 4M > SD2/SD 3M > SD1/LD 2M >
        // MD 1M; unknown keys fall back to the options level
        // (level * 1M), then 0. The options level agrees with the
        // table for the modern keys (ld 1, sd 2, origin 3).
        func rank(of key: String) -> Int {
            switch key.uppercased() {
            case "ORIGIN", "ORIGION": return 6_000_000
            case "FULL_HD1", "UHD": return 5_000_000
            case "HD1", "HD": return 4_000_000
            case "SD2", "SD": return 3_000_000
            case "SD1", "LD": return 2_000_000
            case "MD": return 1_000_000
            default:
                if let level = qualityInfo[key]?.level, level > 0 { return level * 1_000_000 }
                return 0
            }
        }
        // Higher rank first (原画 > 超清 > 高清 > 标清), then the rest.
        // Equal ranks tie-break by key name: the key list is built
        // partly from dictionary keys, whose order is not stable —
        // without this, two equal-rank tiers could swap buttons
        // between loads.
        keys.sort {
            let a = rank(of: $0), b = rank(of: $1)
            return a != b ? a > b : $0 < $1
        }
        var streams: [PlayStream] = []
        var emittedURLs: Set<String> = []
        for key in keys {
            if key == "ao" { continue } // audio-only pull URL, no video
            var urls = modern[key] ?? []
            if let flv = legacyFLV[key], !urls.contains(flv) { urls.append(flv) }
            if let hls = legacyHLS[key], !urls.contains(hls) { urls.append(hls) }
            guard !urls.isEmpty else { continue }
            let display = qualityInfo[key]?.name
                ?? resolutionNames[key]
                ?? Self.qualityNames[key.uppercased()]
                ?? key
            var lineIndex = 0
            for urlString in urls {
                guard !emittedURLs.contains(urlString), let url = URL(string: urlString) else { continue }
                emittedURLs.insert(urlString)
                streams.append(PlayStream(
                    url: url,
                    quality: display,
                    line: lineIndex == 0 ? "主线路" : "线路\(lineIndex + 1)",
                    headers: headers
                ))
                lineIndex += 1
            }
        }
        return streams
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                // The WS wants the room's internal id_str, not the
                // web_rid from the page URL; resolve it first.
                var wsRoomID = roomID
                if let roomInfo = try? await self.roomInfo(for: roomID),
                   let idStr = roomInfo["room"]["id_str"].stringValue, !idStr.isEmpty {
                    wsRoomID = idStr
                }
                #if !os(Linux)
                for await item in DouyinDanmaku.stream(roomID: wsRoomID) {
                    continuation.yield(item)
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Page helpers

    private func pageHTML(path: String, headers: [String: String] = [:]) async throws -> String {
        let data = try await http.get("\(Self.webBase)/\(path)", headers: headers)
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return html
    }

    /// wzgrx DouyinApi.isRoomId: digits only, 17 or more. Anything
    /// else is a web_rid (the room's lasting identity) — a long
    /// alphanumeric id must NOT be sent to reflow.
    static func isRoomID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 17 else { return false }
        return trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// roomStore.roomInfo for a web_rid. The room page embeds
    /// roomStore twice — an empty initial store, then the hydrated
    /// one — so the first populated copy wins; a page whose store
    /// never hydrates has no room to show. Pure Live dispatches by
    /// id shape (douyin_api.dart:99, isRoomId): digits-only 17+ is
    /// the 19-digit internal id (reflow/info API), anything else is
    /// a web_rid (enter API, then HTML).
    private func roomInfo(for roomID: String) async throws -> JSONValue {
        if let cached = Self.cachedRoomInfo(for: roomID) { return cached }
        var info: JSONValue
        if Self.isRoomID(roomID) {
            // 19-digit internal id (the ids feed/category return):
            // reflow/info — Pure Live's ByRoomId route. The room
            // page cannot serve these ids.
            info = try await roomInfoFromReflow(roomID: roomID)
        } else if let entered = try? await roomInfoFromEnter(webRID: roomID) {
            // Short web_rid: signed enter API first (Pure Live's
            // primary ByWebRid route), the hydrated room page as
            // fallback. The page fetch MUST carry the browser headers
            // (build 9 sent none — the page came back 200 with an
            // empty body).
            info = entered
        } else {
            let headers = await Self.requestHeaders()
            let html = try await pageHTML(path: roomID, headers: headers)
            let stores = HaoText.extractAllEscapedJSONObjects(html, marker: "roomStore").compactMap { text -> JSONValue? in
                guard let data = text.data(using: .utf8) else { return nil }
                return JSONValue.parse(data)
            }
            guard let roomInfo = Self.roomInfo(fromRoomStores: stores) else {
                throw LiveSiteError.roomNotFound(roomID)
            }
            info = roomInfo
        }
        // Build 19: prefer reflow/info's stream for rooms opened by
        // web_rid. The enter/HTML route's stream_url is the same
        // shape, but the reflow endpoint's is verified live (EQ118:
        // FLV + HLS both 200, room live with 155k viewers) while the
        // enter route's stream failed to open on the device
        // ("loading failed" on every candidate). A reflow failure
        // keeps the enter stream.
        if !Self.isRoomID(roomID) {
            info = await enrichStreamFromReflow(info)
        }
        Self.storeRoomInfo(info, for: roomID)
        return info
    }

    /// Replace the room's stream_url with reflow/info's when the
    /// room's internal 19-digit id is known. Returns the input
    /// unchanged when the id is missing or reflow fails/returns no
    /// stream.
    private func enrichStreamFromReflow(_ info: JSONValue) async -> JSONValue {
        let room = info["room"]
        let internalID = room["id_str"].stringValue ?? room["id"].stringValue ?? ""
        guard Self.isRoomID(internalID),
              let reflow = try? await roomInfoFromReflow(roomID: internalID),
              !reflow["room"]["stream_url"].isNull else { return info }
        var roomDict = room.objectValue
        roomDict["stream_url"] = reflow["room"]["stream_url"]
        return .object([
            "room": .object(roomDict),
            "anchor": info["anchor"],
            "web_stream_url": reflow["room"]["stream_url"],
            "room_status": info["room_status"],
        ])
    }

    /// reflow/info — Pure Live's ByRoomId route
    /// (douyin_site.dart:695-710). Returns the roomInfo-shaped
    /// object the rest of the site expects: {room, anchor,
    /// web_stream_url}. VM-verified 2026-11-27: HTTP 200,
    /// data.room status 2 with stream_url (flv_pull_url
    /// FULL_HD1/SD1/SD2 + hls_pull_url_map +
    /// live_core_sdk_data.pull_data.options.qualities).
    private func roomInfoFromReflow(roomID: String) async throws -> JSONValue {
        let url = "https://webcast.amemv.com/webcast/room/reflow/info/?type_id=0&live_id=1&room_id=\(roomID)&sec_user_id=&version_code=99.99.99&app_id=6383"
        guard let json = try? await http.getJSON(url, headers: await Self.requestHeaders()),
              json["status_code"].intValue == 0,
              !json["data"]["room"].isNull else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let room = json["data"]["room"]
        return .object([
            "room": room,
            "anchor": room["owner"],
            "web_stream_url": room["stream_url"],
        ])
    }

    /// Signed enter API — Pure Live's primary ByWebRid route
    /// (douyin_site.dart:680-692, signed via buildRequestUrl = the
    /// same a_bogus signing as the category API). Returns the
    /// roomInfo-shaped object. The room is data.data[0] (data itself
    /// is an object, not the list — douyin_api.dart:359-383); the
    /// streamer is data.user when the room is offline, room.owner
    /// when live. room_status is passed through so room() can decide
    /// liveness when room.status is missing. Verified 2026-11-28:
    /// the enter/feed/partition APIs answer from this VM now (the
    /// old "empty body" note was an egress-IP artifact of that time);
    /// on a China IP it is the primary path. Kept because Pure Live
    /// proves it works there.
    private func roomInfoFromEnter(webRID: String) async throws -> JSONValue {
        let params: [(String, String)] = [
            ("app_name", "douyin_web"),
            ("enter_from", "web_live"),
            ("live_id", "1"),
            ("web_rid", webRID),
            ("is_need_double_stream", "false"),
        ]
        let url = DouyinURLSigning.signedURL(base: "https://live.douyin.com/webcast/room/web/enter/", params: params)
        guard let json = try? await http.getJSON(url, headers: await Self.requestHeaders()),
              json["status_code"].intValue == 0,
              !json["data"]["data"][0].isNull else {
            throw LiveSiteError.roomNotFound(webRID)
        }
        let data = json["data"]
        let room = data["data"][0]
        let live = room["status"].intValue == 2
        let anchor = live ? room["owner"] : (!data["user"].isNull ? data["user"] : room["owner"])
        return .object([
            "room": room,
            "anchor": anchor,
            "web_stream_url": room["stream_url"],
            "room_status": data["room_status"],
        ])
    }

    /// Pick the hydrated roomInfo from the page's roomStore objects.
    /// Testable without the network.
    static func roomInfo(fromRoomStores stores: [JSONValue]) -> JSONValue? {
        for store in stores {
            let roomInfo = store["roomInfo"]
            if !roomInfo.isNull, !roomInfo["room"].isNull {
                return roomInfo
            }
        }
        return nil
    }

    /// Extract an object from the page's escaped JSON blob.
    /// Testable without the network.
    static func extractEscapedObject(marker: String, in html: String) -> JSONValue? {
        guard let text = HaoText.extractEscapedJSONObject(html, marker: marker),
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return json
    }

    // MARK: - Mapping helpers

    /// Pure parser for a roomInfo object. Testable without the network.
    static func room(fromRoomInfo info: JSONValue, webRID: String) -> LiveRoom {
        let room = info["room"]
        let anchor = info["anchor"]
        return LiveRoom(
            id: "douyin-\(webRID)",
            platform: .douyin,
            roomID: webRID,
            title: room["title"].stringValue ?? "",
            anchorName: anchor["nickname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(anchor["avatar_thumb"]["url_list"][0].stringValue),
            coverURL: Self.imageURL(firstImageURL([room["cover"]])),
            categoryName: nil,
            viewerCount: Int(room["user_count_str"].stringValue ?? "") ?? room["user_count"].intValue ?? 0,
            isLive: Self.isLive(room: room, roomStatus: info["room_status"])
        )
    }

    /// wzgrx DouyinApi._isLive (douyin_api.dart:526-530): status 2 is
    /// live, any other present status is offline; a missing status
    /// defers to room_status (0 live, 2 ended). Without either the
    /// room is offline.
    static func isLive(room: JSONValue, roomStatus: JSONValue) -> Bool {
        if let status = room["status"].intValue { return status == 2 }
        return roomStatus.intValue == 0
    }

    /// Pure parser for the /webcast/feed/ response — both generations.
    /// Legacy: rooms at data.data. Since Aug 2026: data is a list of
    /// feed envelopes, each envelope's `data` field holding the room
    /// (as an object, or as a JSON string). The room id prefers
    /// web_rid (what the room page + play URLs need); id_str is the
    /// WS id, not the page id. Duplicates are dropped.
    /// Testable without the network.
    static func rooms(fromFeed payload: JSONValue) -> [LiveRoom] {
        if let code = payload["status_code"].intValue, code != 0 { return [] }
        var raw = payload["data"]
        if !raw["data"].isNull { raw = raw["data"] } // legacy envelope
        var rooms: [LiveRoom] = []
        var seen: Set<String> = []
        for envelope in raw.arrayValue {
            let embedded = decodeEmbedded(envelope["data"])
            let candidates: [JSONValue] = [embedded, envelope["room"], envelope].compactMap { $0 }
            guard let room = candidates.first(where: { looksLikeRoom($0) }) else { continue }
            let owner = !room["owner"].objectValue.isEmpty ? room["owner"]
                : (!envelope["owner"].objectValue.isEmpty ? envelope["owner"] : .null)
            let roomID = firstText([envelope["web_rid"], owner["web_rid"], room["web_rid"], room["id_str"], room["id"]])
            guard !roomID.isEmpty, seen.insert(roomID).inserted else { continue }
            let title = firstText([room["title"], envelope["title"], owner["nickname"]])
            let nick = firstText([owner["nickname"], envelope["nickname"]])
            let cover = firstImageURL([room["cover"], envelope["cover"]])
            let avatar = firstImageURL([owner["avatar_thumb"], owner["avatar_large"], envelope["avatar_thumb"]])
            let area = feedArea(envelope: envelope, room: room)
            rooms.append(LiveRoom(
                id: "douyin-\(roomID)",
                platform: .douyin,
                roomID: roomID,
                title: title,
                anchorName: nick,
                anchorAvatarURL: Self.imageURL(avatar),
                coverURL: Self.imageURL(cover),
                categoryName: area.isEmpty ? nil : area,
                viewerCount: onlineViewers(room),
                isLive: true
            ))
        }
        return rooms
    }

    /// Pure parser for one item of the v2 partition room list
    /// (data.data): room under "room", web_rid + tag_name at item level.
    /// The area is tag_name, else areaName (the amemv host leaves
    /// tag_name empty) — wzgrx DouyinApi.partitionRooms.
    /// Testable without the network.
    static func room(fromCategoryItem item: JSONValue, areaName: String? = nil) -> LiveRoom? {
        let room = item["room"]
        guard !room.isNull else { return nil }
        let roomID = firstText([item["web_rid"], room["web_rid"], room["id_str"]])
        guard !roomID.isEmpty else { return nil }
        let owner = room["owner"]
        let tag = item["tag_name"].stringValue
        let area = !(tag ?? "").isEmpty ? tag : ((areaName ?? "").isEmpty ? nil : areaName)
        return LiveRoom(
            id: "douyin-\(roomID)",
            platform: .douyin,
            roomID: roomID,
            title: room["title"].stringValue ?? "",
            anchorName: owner["nickname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(owner["avatar_thumb"]["url_list"][0].stringValue),
            coverURL: Self.imageURL(room["cover"]["url_list"][0].stringValue),
            categoryName: area,
            viewerCount: onlineViewers(room),
            isLive: true
        )
    }

    /// A JSON object (or a JSON string holding one) — the embedded
    /// room in a feed envelope's `data` field.
    static func decodeEmbedded(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .object: return value
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let json = JSONValue.parse(data) else { return nil }
            return json
        default: return nil
        }
    }

    /// Pure Live's _looksLikeRoom: an owner object, a title, an
    /// id_str, or a stream_url object.
    static func looksLikeRoom(_ value: JSONValue) -> Bool {
        !value["owner"].objectValue.isEmpty
            || !value["title"].isNull
            || !value["id_str"].isNull
            || !value["stream_url"].objectValue.isEmpty
    }

    /// First candidate that reads as a non-empty string (numbers
    /// coerce via stringValue; objects/arrays have no stringValue and
    /// are skipped, as is the literal "null").
    static func firstText(_ candidates: [JSONValue]) -> String {
        for value in candidates {
            guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty, text != "null" else { continue }
            return text
        }
        return ""
    }

    /// First candidate that yields an image URL: a {url_list: [...]}
    /// object's first entry, or a bare http(s) string.
    static func firstImageURL(_ candidates: [JSONValue]) -> String {
        for value in candidates {
            if let url = value["url_list"][0].stringValue, !url.isEmpty { return url }
            if let text = value.stringValue, text.hasPrefix("http") { return text }
        }
        return ""
    }

    /// Feed area: tag_name first, then the first title in the
    /// partition_road_map / tags lists, else "热门推荐".
    static func feedArea(envelope: JSONValue, room: JSONValue) -> String {
        let direct = firstText([room["tag_name"], envelope["tag_name"]])
        if !direct.isEmpty { return direct }
        for source in [room["partition_road_map"], envelope["tags"]] {
            for tag in source.arrayValue {
                let text = firstText([tag["title"], tag["name"], tag["tag_name"]])
                if !text.isEmpty { return text }
            }
        }
        return "热门推荐"
    }

    /// Concurrent viewers, Pure Live's douyinOnlineViewers order:
    /// room user_count first, then the room_view_stats / stats
    /// nested counts. A "1.2万" style string does not parse as Int
    /// and is skipped, like the old user_count-only read.
    static func onlineViewers(_ room: JSONValue) -> Int {
        let viewStats = room["room_view_stats"]
        let stats = room["stats"]
        for value in [room["user_count"], room["user_count_str"],
                      room["online_user_count"], room["online_user_for_anchor"],
                      viewStats["user_count"], viewStats["online_user_count"],
                      viewStats["online_user_for_anchor"],
                      stats["user_count"], stats["online_user_count"],
                      stats["online_user_for_anchor"]] {
            if let count = value.intValue { return count }
        }
        return 0
    }
}
