// YYSite.swift
// HAo Live — real YY直播 adapter (anonymous, no login).
// Endpoints (Pure Live's yy_site.dart, ported; list/detail/search
// verified live from this VM 2026-11-28, stream-manager timed out
// from this VM so that leg is unconfirmed here — see playURLs):
//   categories  GET https://www.yy.com/yyweb/module/data/header
//               -> {categoryTabs: [{id, title}]}; subcategories
//               GET https://www.yy.com/c/yycom/category/getCategory.action
//               ?parentId={id} -> {data: [{id, title, cover, url}]};
//               each subcategory's page HTML embeds
//               pageInfo = {moduleId, biz, subBiz} (regex), which is
//               the query a category listing needs. categories()
//               returns the flat subcategory list (each id carries
//               its pageInfo); a top tab alone lists nothing.
//   recommend   GET https://www.yy.com/more/page.action
//               ?page=&pageSize=&biz=other&subBiz=idx&moduleId=-1
//               -> {data: {data: [{sid, desc, name, thumb2, avatar,
//                  users, biz, uid}]}} — desc may end with
//               "正在直播", stripped for display.
//   category    Same more/page.action with the pageInfo query
//               (page, pageSize, moduleId, biz, subBiz).
//   search      GET https://www.yy.com/apiSearch/doSearch.json
//               ?q=&t=120&n={page} (rooms; t=1 searches anchors)
//               -> {data: {searchResult: {response: {"120": {docs:
//                  [{sid, channelName, name, posterurl, headurl,
//                  users, biz, liveOn}]}}}}}
//   detail      GET https://www.yy.com/api/liveInfoDetail/{sid}/{sid}/0
//               -> {resultCode: 0, data: {sid, ssid, uid, desc, name,
//                  thumb2, avatar, users, biz}} — topSid = sid,
//               subSid = ssid (danmaku + stream-manager channel ids,
//               carried on the room's playDataJSON).
//   play        Preferred: POST https://stream-manager.yy.com/
//               v3/channel/streams?uid=0&cid=&sid=&appid=0&sequence=
//               &encode=json (SDK 5.23.0-beta.2, JSON body sent as
//               text/plain) -> channel_stream_info.streams[].json
//               (gear_info{name, gear} + rate = quality tiers) and
//               avp_info_res.stream_line_addr[].cdn_info.url (lines).
//               On any failure (some official channels answer
//               ErrAuthNotPass): anonymous mobile HLS fallback
//               GET https://interface.yy.com/hls/new/get/{cid}/{sid}/
//               {rate}?source=wapyy&callback= (rate 1200 流畅 /
//               4000 高清; iPhone UA + wap Referer) -> JSONP-ish
//               {"code":0, "hls": "...", "width", "height", "video"}.
//               Signed query parameters are kept verbatim.
// Danmaku: YyDanmaku (wss://h5-sinchl.yy.com/websocket + the H5
// binary protocol: anonymous UDB login -> AP login -> join channel).
// No login anywhere; no cookie is required.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class YYSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .yy
    private let http = HTTPClient.shared

    private static let webBase = "https://www.yy.com"
    private static let streamSDKVersion = "5.23.0-beta.2"
    private static let mobileHLSRates = ["1200", "4000"]
    private static let pageSize = 30

    private static let headers: [String: String] = [
        "Accept": "*/*",
        "Origin": "https://www.yy.com",
        "Referer": "https://www.yy.com/",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-site",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
    ]

    private static let presetBizAreaNames: [String: String] = [
        "sing": "音乐", "talk": "脱口秀", "dance": "舞蹈", "red": "户外",
        "pretty": "颜值", "mc": "喊麦", "sport": "体育", "car": "二次元",
        "game": "王者荣耀", "zonghe": "综合",
    ]

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.webBase)/yyweb/module/data/header", headers: Self.headers)
        let tabs = json["categoryTabs"].arrayValue.compactMap { item -> (id: String, title: String)? in
            guard let id = item["id"].stringValue, !id.isEmpty,
                  let title = item["title"].stringValue, !title.isEmpty else { return nil }
            return (id: id, title: title)
        }
        guard !tabs.isEmpty else { return [] }
        // Subcategories per top tab, fetched in parallel (the same
        // shape as Pure Live's Future.wait over the tabs).
        var all: [LiveCategory] = []
        try await withThrowingTaskGroup(of: [LiveCategory].self) { group in
            for tab in tabs {
                group.addTask { try await self.subCategories(tabID: tab.id, tabTitle: tab.title) }
            }
            for try await subs in group {
                all.append(contentsOf: subs)
            }
        }
        return all
    }

    /// Subcategories of one top tab. A subcategory without a usable
    /// pageInfo is dropped — without moduleId/biz/subBiz its rooms
    /// cannot be listed.
    private func subCategories(tabID: String, tabTitle: String) async throws -> [LiveCategory] {
        let json = try await http.getJSON(
            "\(Self.webBase)/c/yycom/category/getCategory.action?parentId=\(tabID)",
            headers: Self.headers
        )
        var out: [LiveCategory] = []
        for item in json["data"].arrayValue {
            guard item["id"].stringValue != nil,
                  let title = item["title"].stringValue, !title.isEmpty else { continue }
            var pageInfo: (moduleID: Int, biz: String, subBiz: String)? = nil
            if let urlString = item["url"].stringValue, !urlString.isEmpty,
               let url = URL(string: urlString.hasPrefix("http") ? urlString : "\(Self.webBase)\(urlString)"),
               let data = try? await http.get(url.absoluteString, headers: Self.headers),
               let html = String(data: data, encoding: .utf8) {
                pageInfo = Self.parseCategoryPageInfo(html)
            }
            guard let info = pageInfo else { continue }
            out.append(LiveCategory(
                id: "yy-page:\(info.moduleID):\(info.biz):\(info.subBiz)",
                platform: .yy,
                name: title,
                iconName: nil,
                iconURL: Self.imageURL(item["cover"].stringValue)
            ))
        }
        return out
    }

    /// Reads moduleId / biz / subBiz out of a category page's
    /// `pageInfo = {...};` JavaScript object. Pure function.
    static func parseCategoryPageInfo(_ html: String) -> (moduleID: Int, biz: String, subBiz: String)? {
        guard let object = firstGroup(#"pageInfo\s*=\s*(\{[\s\S]*?\})\s*;"#, in: html) else { return nil }
        guard let moduleIDString = firstGroup(#"moduleId\s*:\s*['"]?(-?\d+)"#, in: object),
              let moduleID = Int(moduleIDString),
              let biz = firstGroup(#"biz\s*:\s*['"]([^'"]+)"#, in: object), !biz.isEmpty,
              let subBiz = firstGroup(#"subBiz\s*:\s*['"]([^'"]+)"#, in: object), !subBiz.isEmpty else { return nil }
        return (moduleID: moduleID, biz: biz, subBiz: subBiz)
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let json = try await http.getJSON(
            "\(Self.webBase)/more/page.action?page=\(page)&pageSize=\(Self.pageSize)&biz=other&subBiz=idx&moduleId=-1",
            headers: Self.headers
        )
        return json["data"]["data"].arrayValue.map { Self.room(fromListItem: $0, categoryName: nil) }
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page >= 1,
              let info = Self.pageInfo(from: category.id) else { return [] }
        let biz = info.biz.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? info.biz
        let subBiz = info.subBiz.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? info.subBiz
        let json = try await http.getJSON(
            "\(Self.webBase)/more/page.action?page=\(page)&pageSize=\(Self.pageSize)&biz=\(biz)&subBiz=\(subBiz)&moduleId=\(info.moduleID)",
            headers: Self.headers
        )
        return json["data"]["data"].arrayValue.map { Self.room(fromListItem: $0, categoryName: category.name) }
    }

    /// "yy-page:{moduleId}:{biz}:{subBiz}" -> its parts.
    static func pageInfo(from categoryID: String) -> (moduleID: Int, biz: String, subBiz: String)? {
        guard categoryID.hasPrefix("yy-page:") else { return nil }
        let parts = categoryID.dropFirst("yy-page:".count).split(separator: ":").map(String.init)
        guard parts.count == 3, let moduleID = Int(parts[0]),
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (moduleID: moduleID, biz: parts[1], subBiz: parts[2])
    }

    /// Pure parser for a more/page.action list item.
    static func room(fromListItem item: JSONValue, categoryName: String?) -> LiveRoom {
        let sid = item["sid"].stringValue ?? ""
        let biz = item["biz"].stringValue ?? ""
        return LiveRoom(
            id: "yy-\(sid)",
            platform: .yy,
            roomID: sid,
            title: Self.stripLiveSuffix(item["desc"].stringValue ?? ""),
            anchorName: item["name"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(item["avatar"].stringValue),
            coverURL: Self.imageURL(item["thumb2"].stringValue),
            categoryName: categoryName ?? areaName(forBiz: biz),
            viewerCount: item["users"].intValue ?? 0,
            isLive: true
        )
    }

    static func areaName(forBiz biz: String) -> String? {
        if biz.isEmpty { return nil }
        return presetBizAreaNames[biz] ?? biz
    }

    static func stripLiveSuffix(_ text: String) -> String {
        let suffix = "正在直播"
        guard text.hasSuffix(suffix) else { return text }
        return String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchAnchors(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let docs = try await searchDocs(keyword: keyword, type: 120, page: page)
        return docs.map { doc in
            let sid = doc["sid"].stringValue ?? ""
            return LiveRoom(
                id: "yy-\(sid)",
                platform: .yy,
                roomID: sid,
                title: Self.stripLiveSuffix(doc["channelName"].stringValue ?? ""),
                anchorName: doc["name"].stringValue ?? "",
                anchorAvatarURL: Self.imageURL(doc["headurl"].stringValue),
                coverURL: Self.imageURL(doc["posterurl"].stringValue),
                categoryName: Self.areaName(forBiz: doc["biz"].stringValue ?? ""),
                viewerCount: doc["users"].intValue ?? 0,
                isLive: Self.isLiveValue(doc["liveOn"])
            )
        }
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        let docs = try await searchDocs(keyword: keyword, type: 1, page: page)
        return docs.map { doc in
            let sid = HaoText.firstNonEmpty(doc["sid"].stringValue, doc["ssid"].stringValue) ?? ""
            let name = HaoText.firstNonEmpty(doc["name"].stringValue, doc["stageName"].stringValue) ?? ""
            return LiveRoom(
                id: "yy-\(sid)",
                platform: .yy,
                roomID: sid,
                title: name,
                anchorName: name,
                anchorAvatarURL: Self.imageURL(doc["headurl"].stringValue),
                coverURL: nil,
                categoryName: nil,
                viewerCount: 0,
                isLive: Self.isLiveValue(doc["liveOn"])
            )
        }
    }

    private func searchDocs(keyword: String, type: Int, page: Int) async throws -> [JSONValue] {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, page >= 1 else { return [] }
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let json = try await http.getJSON(
            "\(Self.webBase)/apiSearch/doSearch.json?q=\(encoded)&t=\(type)&n=\(page)",
            headers: Self.headers
        )
        return json["data"]["searchResult"]["response"]["\(type)"]["docs"].arrayValue
    }

    static func isLiveValue(_ value: JSONValue) -> Bool {
        if let bool = value.boolValue { return bool }
        switch value.stringValue?.lowercased() {
        case "1", "true", "live": return true
        default: return false
        }
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let sid = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else { throw LiveSiteError.roomNotFound(roomID) }
        let json = try await http.getJSON(
            "\(Self.webBase)/api/liveInfoDetail/\(sid)/\(sid)/0",
            headers: Self.headers
        )
        guard json["resultCode"].intValue == 0 else { throw LiveSiteError.roomNotFound(roomID) }
        let data = json["data"]
        guard !data.isNull else {
            return LiveRoom(
                id: "yy-\(sid)", platform: .yy, roomID: sid, title: "",
                anchorName: "", anchorAvatarURL: nil, coverURL: nil,
                categoryName: nil, viewerCount: 0, isLive: false
            )
        }
        let topSid = data["sid"].intValue ?? Int(sid) ?? 0
        let subSid = data["ssid"].intValue ?? topSid
        return LiveRoom(
            id: "yy-\(sid)",
            platform: .yy,
            roomID: data["sid"].stringValue ?? sid,
            title: Self.stripLiveSuffix(data["desc"].stringValue ?? ""),
            anchorName: data["name"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(data["avatar"].stringValue),
            coverURL: Self.imageURL(data["thumb2"].stringValue),
            categoryName: Self.areaName(forBiz: data["biz"].stringValue ?? ""),
            viewerCount: data["users"].intValue ?? 0,
            isLive: true,
            playDataJSON: "{\"topSid\":\(topSid),\"subSid\":\(subSid)}"
        )
    }

    /// Channel ids for stream-manager / danmaku: (cid, sid). From the
    /// room's playDataJSON when present, else the room id for both.
    static func channelIDs(for room: LiveRoom) -> (cid: String, sid: String) {
        if let data = room.playDataJSON.flatMap({ $0.data(using: .utf8) }),
           let json = JSONValue.parse(data),
           let top = json["topSid"].intValue, top > 0 {
            let sub = json["subSid"].intValue ?? top
            return (cid: "\(top)", sid: "\(sub)")
        }
        return (cid: room.roomID, sid: room.roomID)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        // Preferred route: stream-manager, all gears x all lines.
        if let streams = try? await streamManagerStreams(room: room), !streams.isEmpty {
            return streams
        }
        // Fallback: anonymous mobile HLS (1200 流畅 / 4000 高清).
        return await mobileHLSStreams(room: room)
    }

    /// Stream-manager qualities for gear "1", then one URL fetch per
    /// gear. Throws when the manager answers nothing usable (the
    /// caller falls back to mobile HLS).
    private func streamManagerStreams(room: LiveRoom) async throws -> [PlayStream] {
        let first = try await streamManagerObject(room: room, gear: 1)
        let qualities = Self.parsePlayQualities(first)
        guard !qualities.isEmpty else { return [] }
        let headers = PlaybackHeaders.headers(platform: .yy, roomID: room.roomID)
        var out: [PlayStream] = []
        for quality in qualities {
            let object = try await streamManagerObject(room: room, gear: quality.gear)
            let urls = Self.parsePlayURLs(object)
            for (index, urlString) in urls.enumerated() {
                guard let url = URL(string: urlString) else { continue }
                out.append(PlayStream(
                    url: url, quality: quality.name,
                    line: "线路\(index + 1)", headers: headers
                ))
            }
        }
        return out
    }

    /// One stream-manager call for a gear. Pure Live's body, sent as
    /// text/plain (some protected channels reject application/json
    /// before evaluating the otherwise identical request).
    private func streamManagerObject(room: LiveRoom, gear: Int) async throws -> JSONValue {
        let channel = Self.channelIDs(for: room)
        let sequence = Int(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "head": [
                "seq": sequence, "appidstr": "0", "bidstr": "121",
                "cidstr": channel.sid, "sidstr": channel.sid, "uid64": 0,
                "client_type": 108, "client_ver": Self.streamSDKVersion,
                "stream_sys_ver": 1, "app": "yylive_web",
                "playersdk_ver": Self.streamSDKVersion,
                "thundersdk_ver": "0", "streamsdk_ver": Self.streamSDKVersion,
            ],
            "client_attribute": [
                "client": "web", "model": "web0", "cpu": "",
                "graphics_card": "", "os": "chrome",
                "osversion": "128.0.0.0", "vsdk_version": "",
                "app_identify": "", "app_version": "", "business": "",
                "width": "1366", "height": "768", "scale": "",
                "client_type": 8, "h265": 0,
            ],
            "avp_parameter": [
                "version": 1, "client_type": 8, "service_type": 0,
                "imsi": 0, "send_time": sequence / 1000, "line_seq": -1,
                "gear": gear, "ssl": 1, "stream_format": 0,
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        let query = "uid=0&cid=\(channel.sid)&sid=\(channel.sid)&appid=0&sequence=\(sequence)&encode=json"
        return try await http.postJSONParsed(
            "https://stream-manager.yy.com/v3/channel/streams?\(query)",
            jsonData: bodyData,
            headers: Self.headers.merging(
                ["Content-Type": "text/plain;charset=UTF-8",
                 "Referer": "https://www.yy.com/\(channel.cid)/\(channel.sid)"],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    /// Pure parser: gear tiers from channel_stream_info.streams.
    /// Each stream's `json` field is itself a JSON string carrying
    /// gear_info{name, gear} + rate.
    static func parsePlayQualities(_ payload: JSONValue) -> [(name: String, gear: Int, rate: Int)] {
        var seen = Set<Int>()
        var records: [(name: String, gear: Int, rate: Int)] = []
        for stream in payload["channel_stream_info"]["streams"].arrayValue {
            guard let jsonText = stream["json"].stringValue,
                  let data = jsonText.data(using: .utf8),
                  let decoded = JSONValue.parse(data) else { continue }
            let gearInfo = decoded["gear_info"]
            guard let name = gearInfo["name"].stringValue, !name.isEmpty,
                  let gear = gearInfo["gear"].intValue,
                  seen.insert(gear).inserted else { continue }
            records.append((name: name, gear: gear, rate: decoded["rate"].intValue ?? 0))
        }
        // Same name twice (different gears) keeps the gear in the label.
        let nameCounts = Dictionary(grouping: records, by: { $0.name }).mapValues { $0.count }
        let labeled = records.map { record in
            (name: (nameCounts[record.name] ?? 0) > 1 ? "\(record.name) · \(record.gear)" : record.name,
             gear: record.gear, rate: record.rate)
        }
        return labeled.sorted { $0.rate > $1.rate }
    }

    /// Pure parser: line URLs from avp_info_res.stream_line_addr.
    static func parsePlayURLs(_ payload: JSONValue) -> [String] {
        var urls: [String] = []
        for (_, value) in payload["avp_info_res"]["stream_line_addr"].objectValue {
            var url = value["cdn_info"]["url"].stringValue ?? ""
            if url.hasPrefix("//") { url = "https:" + url }
            guard let parsed = URL(string: url),
                  parsed.scheme == "http" || parsed.scheme == "https",
                  !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Mobile HLS fallback (verified live from this VM 2026-11-28).
    private func mobileHLSStreams(room: LiveRoom) async -> [PlayStream] {
        let channel = Self.channelIDs(for: room)
        var byIdentity: [String: PlayStream] = [:]
        for rate in Self.mobileHLSRates {
            guard let payload = try? await mobileHLSPayload(channel: channel, rate: rate),
                  let hls = payload["hls"].stringValue, !hls.isEmpty,
                  let url = URL(string: hls) else { continue }
            let width = payload["width"].intValue ?? 0
            let height = payload["height"].intValue ?? 0
            let shortEdge = width > 0 && height > 0 ? min(width, height) : 0
            let identity = payload["video"].stringValue ?? "\(width)x\(height)"
            let tier = rate == Self.mobileHLSRates.first ? "流畅" : "高清"
            let quality = shortEdge > 0 ? "\(tier) · \(shortEdge)p" : tier
            let headers: [String: String] = [
                "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
                "origin": "https://www.yy.com",
                "referer": "https://wap.yy.com/mobileweb/\(channel.cid)/\(channel.sid)",
            ]
            // Several requested rates can map to the same source; keep
            // only the highest request for it (Pure Live's rule).
            byIdentity[identity] = PlayStream(url: url, quality: quality, line: "主线路", headers: headers)
        }
        return byIdentity.values.sorted { a, b in
            // "高清" sorts above "流畅" (both carry the same shape).
            a.quality > b.quality
        }
    }

    /// One mobile-HLS call. The response is JSONP-ish: `({...})`.
    private func mobileHLSPayload(channel: (cid: String, sid: String), rate: String) async throws -> JSONValue {
        let url = "https://interface.yy.com/hls/new/get/\(channel.cid)/\(channel.sid)/\(rate)?source=wapyy&callback="
        let data = try await http.get(url, headers: [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://wap.yy.com/mobileweb/\(channel.cid)/\(channel.sid)",
        ])
        guard let payload = Self.parseMobileHLSPayload(data) else {
            throw LiveSiteError.invalidResponse
        }
        return payload
    }

    /// Pure parser for the JSONP-ish mobile-HLS body. Nil unless the
    /// payload decodes and code == 0 with a usable hls URL.
    static func parseMobileHLSPayload(_ data: Data) -> JSONValue? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end,
              let jsonData = String(text[start...end]).data(using: .utf8),
              let json = JSONValue.parse(jsonData),
              json["code"].intValue == 0,
              let hls = json["hls"].stringValue, !hls.isEmpty,
              let url = URL(string: hls),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return json
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return YyDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Regex helper

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
