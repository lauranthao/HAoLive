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
//   play URL: per CDN entry one FLV line (sFlvUrl) and one HLS
//             line (sHlsUrl); each URL is RE-SIGNED with
//             buildAntiCode (viewer UID from anonymousLogin, fm
//             template decoded, wsSecret recomputed, seqid/u added)
//             — Pure Live's getPlayUrl, ported. The raw page
//             template (build 5) is not a playable URL.
//             Qualities from vMultiStreamInfo (iBitRate);
//             ratio replaced per quality, codec=264 forced.
//             Playback headers: HYSDK UA + Origin/Referer.
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
            return LiveCategory(id: "huya-\(id)", platform: .huya, name: name, iconName: nil, iconURL: Self.imageURL(item["imgUrl"].stringValue))
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await liveList(gameID: 0)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await liveList(gameID: 0, page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        let gameID = Int(category.id.dropFirst("huya-".count)) ?? 0
        return try await liveList(gameID: gameID)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let gameID = Int(category.id.dropFirst("huya-".count)) ?? 0
        return try await liveList(gameID: gameID, page: page)
    }

    private func liveList(gameID: Int, page: Int = 1) async throws -> [LiveRoom] {
        let url = "\(Self.webBase)/cache.php?m=LiveList&do=getLiveListByPage&gameId=\(gameID)&tagAll=0&page=\(page)"
        let json = try await http.getJSON(url)
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        return json["data"]["datas"].arrayValue.map(Self.room(fromListItem:))
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

    /// Huya's search API. Unverified from this VM (the response shape
    /// is parsed defensively); needs a device to confirm.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://search.huya.com/api/search?huyaSearchType=live&search=\(encoded)&page=\(page)"
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
            anchorAvatarURL: Self.imageURL(profile?["avatar"].stringValue),
            coverURL: Self.imageURL(roomData["screenshot"].stringValue),
            categoryName: roomData["gameFullName"].stringValue,
            viewerCount: roomData["totalCount"].intValue ?? 0,
            isLive: roomData["state"].stringValue == "ON" || roomData["isOn"].boolValue == true
        )
    }

    // MARK: - Play URLs (Pure Live's Huya route, ported)
    //
    // Per room page (hyPlayerConfig.stream):
    //   - each gameStreamInfoList entry yields TWO lines: FLV
    //     (sFlvUrl) and HLS (sHlsUrl), sharing sFlvAntiCode /
    //     sHlsAntiCode, sStreamName, sCdnType; presenterUid is the
    //     first entry's lChannelId.
    //   - qualities come from vMultiStreamInfo (sDisplayName,
    //     iBitRate; HDR skipped); bitRate 0 is source quality.
    //   - every URL is RE-SIGNED with buildAntiCode (Pure Live):
    //     the page template's fm is signing material, not a media
    //     query field — it is decoded, its $0..$3 placeholders are
    //     filled with the viewer UID / stream / signature hash /
    //     wsTime, and the emitted URL carries the recomputed
    //     wsSecret + seqid + u (no fm). Sending the raw template
    //     (what build 5 did) leaves the page's wsSecret in place
    //     with no seqid/u — the CDN rejects it.
    //   - FLV lines prefer Pure Live's native WUP token
    //     (getNativeCdnTokenInfoEx, TARS/TUP); that call is NOT
    //     ported in this leg — FLV uses the web-template fallback
    //     (buildAntiCode on sFlvAntiCode), which Pure Live keeps
    //     for exactly this case.
    //   - ratio is replaced per quality (removed for source);
    //     codec=264 is forced when the anti-code omits it.

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let roomID = room.roomID
        let html = try await roomPage(roomID: roomID)
        guard let stream = Self.extractStreamObject(in: html) else { return [] }
        let viewerUID = await Self.viewerUID()
        let headers = PlaybackHeaders.headers(platform: .huya, roomID: roomID)
        return Self.streams(fromStreamObject: stream, viewerUID: viewerUID, headers: headers)
    }

    /// Pure builder for the hyPlayerConfig.stream object: all
    /// qualities × all lines, best first (source, then bitrate
    /// descending; FLV line before HLS line per CDN entry — Pure
    /// Live's line order). Testable without the network.
    static func streams(fromStreamObject stream: JSONValue, viewerUID: Int, headers: [String: String]) -> [PlayStream] {
        let first = stream["data"][0]
        guard !first.isNull else { return [] }
        var lines: [HuyaLine] = []
        var presenterUID = 0
        let entries = first["gameStreamInfoList"].arrayValue
        if let firstEntry = entries.first {
            presenterUID = firstEntry["lChannelId"].intValue ?? 0
        }
        for entry in entries {
            guard let streamName = entry["sStreamName"].stringValue, !streamName.isEmpty else { continue }
            let cdn = entry["sCdnType"].stringValue ?? ""
            let flvAnti = entry["sFlvAntiCode"].stringValue ?? ""
            let hlsAnti = entry["sHlsAntiCode"].stringValue ?? ""
            if let flvBase = entry["sFlvUrl"].stringValue, !flvBase.isEmpty {
                lines.append(HuyaLine(base: flvBase, cdnType: cdn, streamName: streamName, flvAntiCode: flvAnti, hlsAntiCode: hlsAnti, lineType: .flv, presenterUID: presenterUID))
            }
            if let hlsBase = entry["sHlsUrl"].stringValue, !hlsBase.isEmpty {
                lines.append(HuyaLine(base: hlsBase, cdnType: cdn, streamName: streamName, flvAntiCode: flvAnti, hlsAntiCode: hlsAnti, lineType: .hls, presenterUID: presenterUID))
            }
        }
        guard !lines.isEmpty else { return [] }
        // Qualities: vMultiStreamInfo, HDR and 4K skipped (Pure
        // Live excludes 4K tiers); source (0) first, then bitRate
        // descending.
        var rates: [(name: String, bitRate: Int)] = []
        for item in stream["vMultiStreamInfo"].arrayValue {
            guard let name = item["sDisplayName"].stringValue, !name.isEmpty,
                  !name.contains("HDR"),
                  !name.contains("4K"),
                  let rate = item["iBitRate"].intValue else { continue }
            if !rates.contains(where: { $0.bitRate == rate }) {
                rates.append((name: name, bitRate: rate))
            }
        }
        if !rates.contains(where: { $0.bitRate == 0 }) {
            rates.insert((name: "原画", bitRate: 0), at: 0)
        }
        rates.sort { a, b in
            if (a.bitRate == 0) != (b.bitRate == 0) { return a.bitRate == 0 }
            return a.bitRate > b.bitRate
        }
        var streams: [PlayStream] = []
        // The web-template URL's lease (Pure Live's
        // _transportInvalidAge = 125 s, refresh at 100 s): the
        // service refreshes before it dies. The native WUP token
        // (getNativeCdnTokenInfoEx) is NOT ported in this leg —
        // Pure Live keeps this web-template path as its fallback,
        // and the lease above keeps it renewing.
        let issuedAt = Date()
        for rate in rates {
            for line in lines {
                guard let urlString = Self.playURL(line: line, bitRate: rate.bitRate, viewerUID: viewerUID),
                      let url = URL(string: urlString) else { continue }
                streams.append(PlayStream(
                    url: url,
                    quality: rate.name,
                    line: Self.cdnNames[line.cdnType] ?? (line.cdnType.isEmpty ? "主线路" : line.cdnType),
                    headers: headers,
                    expiresAt: issuedAt.addingTimeInterval(125)
                ))
            }
        }
        return streams
    }

    /// One CDN line (Pure Live's HuyaLineModel, without the WUP lease).
    struct HuyaLine {
        enum Kind { case flv, hls }
        var base: String
        var cdnType: String
        var streamName: String
        var flvAntiCode: String
        var hlsAntiCode: String
        var lineType: Kind
        var presenterUID: Int
    }

    /// Pure Live's getPlayUrl (web-template path): pick the
    /// transport's anti-code, re-sign it with the viewer UID, force
    /// codec=264, replace ratio. Returns nil when no signing
    /// material is available. Testable without the network.
    static func playURL(line: HuyaLine, bitRate: Int, viewerUID: Int) -> String? {
        var antiCode = line.lineType == .flv ? line.flvAntiCode.trimmingCharacters(in: .whitespaces) : line.hlsAntiCode.trimmingCharacters(in: .whitespaces)
        guard !antiCode.isEmpty else { return nil }
        // Web-template fallback: a template without fm is a legacy
        // static token, used as-is; one with fm must be re-signed.
        if antiCode.contains("fm=") {
            guard let signed = try? buildAntiCode(stream: line.streamName, viewerUID: viewerUID, antiCode: antiCode) else { return nil }
            antiCode = signed
        }
        let ext = line.lineType == .hls ? "m3u8" : "flv"
        let cdnBase = Self.secureHuyaCdnBase(line.base)
        if !Self.queryHasKey(antiCode, key: "codec") { antiCode += "&codec=264" }
        antiCode = Self.replaceQueryParameter(antiCode, key: "ratio", value: bitRate > 0 ? String(bitRate) : nil)
        return "\(cdnBase)/\(line.streamName).\(ext)?\(antiCode)"
    }

    /// http -> https, only for Huya hosts (Pure Live's
    /// secureHuyaCdnBase).
    static func secureHuyaCdnBase(_ base: String) -> String {
        guard let url = URL(string: base),
              url.scheme == "http",
              url.host == "huya.com" || (url.host?.hasSuffix(".huya.com") == true),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return base }
        components.scheme = "https"
        return components.string ?? base
    }

    static func queryHasKey(_ query: String, key: String) -> Bool {
        query.split(separator: "&").contains { segment in
            segment.split(separator: "=", maxSplits: 1).first.map(String.init) == key
        }
    }

    /// Replace (or remove) one query parameter, preserving order
    /// (Pure Live's replaceQueryParameter).
    static func replaceQueryParameter(_ query: String, key: String, value: String?) -> String {
        var output: [String] = []
        var replaced = false
        for segment in query.split(separator: "&", omittingEmptySubsequences: true) {
            let segmentKey = segment.split(separator: "=", maxSplits: 1).first.map(String.init) ?? String(segment)
            if segmentKey != key {
                output.append(String(segment))
                continue
            }
            if !replaced, let value {
                output.append("\(key)=\(value)")
            }
            replaced = true
        }
        if !replaced, let value {
            output.append("\(key)=\(value)")
        }
        return output.joined(separator: "&")
    }

    /// Anonymous viewer UID from Huya's anonymousLogin endpoint
    /// (no login). Cached for the process; on failure a stable
    /// process-local fallback UID is used (Pure Live's
    /// _loadAnonymousViewerIdentity / _createFallbackViewerUid).
    /// Shared mutable statics: written idempotently (same value on
    /// repeat). Swift 6 needs the explicit opt-in (same pattern as
    /// OrientationLock.shared / CoverImageCache.shared, build 5).
    nonisolated(unsafe) private static var cachedViewerUID: Int?
    nonisolated(unsafe) private static var fallbackViewerUID: Int?

    static func viewerUID() async -> Int {
        if let cached = cachedViewerUID { return cached }
        if let uid = try? await anonymousLoginUID(), uid > 0 {
            cachedViewerUID = uid
            return uid
        }
        if let fallback = fallbackViewerUID { return fallback }
        let fallback = 1_400_000_000_000 + Int.random(in: 0..<1_000_000) * 100_000 + Int.random(in: 0..<100_000)
        fallbackViewerUID = fallback
        return fallback
    }

    private static func anonymousLoginUID() async throws -> Int {
        let fields: [String: Any] = ["appId": 5002, "byPass": 3, "context": "", "version": "2.4", "data": [:] as [String: Any]]
        let body = try JSONSerialization.data(withJSONObject: fields, options: [])
        var request = URLRequest(url: URL(string: "https://udblgn.huya.com/web/anonymousLogin")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPClient.shared.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.huya.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.huya.com/", forHTTPHeaderField: "Referer")
        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = JSONValue.parse(data),
              let uid = json["data"]["uid"].intValue, uid > 0 else {
            throw LiveSiteError.invalidResponse
        }
        return uid
    }

    /// Pure Live's buildAntiCode: re-sign a page anti-code template
    /// with the viewer UID and the server-issued expiry. The fm
    /// field is a base64 template with $0..$3 placeholders —
    /// $0 = rotated UID, $1 = stream name, $2 = MD5(seqid|ctype|t),
    /// $3 = wsTime — whose MD5 becomes the new wsSecret. The
    /// emitted URL drops fm and carries seqid / u / ctype / ver /
    /// fs / t. Throws when the template is incomplete or expired.
    /// Testable without the network (pass `now`).
    static func buildAntiCode(stream: String, viewerUID: Int, antiCode: String, now: Date = Date()) throws -> String {
        let (originalKeys, original) = Self.parseQuery(antiCode)
        guard let encodedFm = original["fm"], !encodedFm.isEmpty else { return antiCode }
        let ctype = original["ctype"].flatMap { $0.isEmpty ? nil : $0 } ?? "huya_webh5"
        let platformId = original["t"].flatMap { $0.isEmpty ? nil : $0 } ?? "100"
        let isWap = platformId == "103"
        let currentMillis = Int(now.timeIntervalSince1970 * 1000)
        let currentSeconds = currentMillis / 1000
        let uid = viewerUID > 0 ? viewerUID : (fallbackViewerUID ?? 1_400_000_000_000)
        guard let wsTimeRaw = original["wsTime"],
              let wsTimeSeconds = Int(wsTimeRaw, radix: 16) else {
            throw LiveSiteError.invalidResponse
        }
        guard currentSeconds <= wsTimeSeconds + 300 else {
            throw LiveSiteError.invalidResponse // lease expired
        }
        let wsTime = wsTimeRaw.lowercased()
        let seqId = uid + currentMillis
        let secretHash = MD5.hex("\(seqId)|\(ctype)|\(platformId)")
        let convertUid = Self.rotateViewerUid32(uid)
        let calcUid = isWap ? uid : convertUid
        guard let fmData = Data(base64Encoded: Self.paddedBase64(encodedFm)),
              let secretTemplate = String(data: fmData, encoding: .utf8),
              ["$0", "$1", "$2", "$3"].allSatisfy({ secretTemplate.contains($0) }) else {
            throw LiveSiteError.invalidResponse
        }
        let secretStr = secretTemplate
            .replacingOccurrences(of: "$0", with: String(calcUid))
            .replacingOccurrences(of: "$1", with: stream)
            .replacingOccurrences(of: "$2", with: secretHash)
            .replacingOccurrences(of: "$3", with: wsTime)
        let wsSecret = MD5.hex(secretStr)
        let ct = Int((Double(wsTimeSeconds) + Double.random(in: 0..<1)) * 1000)
        let uuid = Int((((Double(ct % 10_000_000_000) + Double.random(in: 0..<1)) * 1_000).truncatingRemainder(dividingBy: 4_294_967_295)))
        var params = original
        params.removeValue(forKey: "wsSecret")
        params.removeValue(forKey: "seqid")
        params.removeValue(forKey: "u")
        params.removeValue(forKey: "uid")
        params.removeValue(forKey: "uuid")
        params.removeValue(forKey: "fm")
        params["wsSecret"] = wsSecret
        params["wsTime"] = wsTime
        params["seqid"] = String(seqId)
        params["ctype"] = ctype
        params["ver"] = "1"
        params["fs"] = original["fs"] ?? "bgct"
        params["t"] = platformId
        if isWap {
            params["uid"] = String(uid)
            params["uuid"] = String(uuid)
        } else {
            params["u"] = String(convertUid)
        }
        return Self.queryString(from: params, orderedKeys: Self.orderedAntiCodeKeys(originalKeys: originalKeys))
    }

    /// Huya's web player rotates only the low 32-bit lane of the
    /// 64-bit viewer UID (rotl by 8); the upper lane is preserved.
    /// (Pure Live's rotateViewerUid32 — "rotl64" in the web player.)
    static func rotateViewerUid32(_ value: Int) -> Int {
        let low = value & 0xFFFF_FFFF
        let high = value - low
        let rotatedLow = ((low << 8) | (low >> 24)) & 0xFFFF_FFFF
        return high | rotatedLow
    }

    /// Parse a query string, keeping the key order (Dart's
    /// Uri.queryParameters is insertion-ordered; Swift's
    /// Dictionary is not, so the order rides alongside).
    static func parseQuery(_ query: String) -> (keys: [String], params: [String: String]) {
        var keys: [String] = []
        var params: [String: String] = [:]
        for segment in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = segment.split(separator: "=", maxSplits: 1)
            guard let key = parts.first.map(String.init) else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if params[key] == nil { keys.append(key) }
            params[key] = value.removingPercentEncoding ?? value
        }
        return (keys, params)
    }

    static func queryParameters(of query: String) -> [String: String] {
        Self.parseQuery(query).params
    }

    /// Rebuild a query string keeping the original key order first,
    /// then any new keys (wsSecret/seqid/... keep a stable order).
    static func queryString(from params: [String: String], orderedKeys: [String]) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for key in orderedKeys where params[key] != nil {
            seen.insert(key)
            parts.append("\(key)=\(params[key]!)")
        }
        for key in params.keys.sorted() where !seen.contains(key) {
            parts.append("\(key)=\(params[key]!)")
        }
        return parts.joined(separator: "&")
    }

    static func orderedAntiCodeKeys(originalKeys: [String]) -> [String] {
        // Keep the page's own key order for keys that survive; the
        // signed keys are appended in Pure Live's insertion order.
        var keys = originalKeys
        for key in ["wsSecret", "wsTime", "seqid", "ctype", "ver", "fs", "t", "u", "uid", "uuid"] where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    static func paddedBase64(_ string: String) -> String {
        var s = string
        while s.count % 4 != 0 { s += "=" }
        return s
    }

    // MARK: - Danmaku

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
            anchorAvatarURL: Self.imageURL(item["avatar180"].stringValue),
            coverURL: Self.imageURL(item["screenshot"].stringValue),
            categoryName: item["gameFullName"].stringValue,
            viewerCount: item["totalCount"].intValue ?? 0,
            isLive: true
        )
    }

}
