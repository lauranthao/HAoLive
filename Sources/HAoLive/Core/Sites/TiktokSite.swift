// TiktokSite.swift
// HAo Live — TikTok LIVE adapter (anonymous, no login).
//
// 形态：本平台无浏览列表与服务端搜索，只能粘贴链接/输入 ID 直达
// （https://www.tiktok.com/@{username}/live、vm.tiktok.com /
// vt.tiktok.com 短链、/share/live/{roomId}，或直接输 @username /
// 用户名 / 19–25 位数字 roomId）。categories() / recommendRooms()
// 一律返回 []，searchRooms() / searchAnchors() 只解析链接或用户名得
// 用户名再调详情，解析不出返回 []，不假装有搜索。弹幕：无（LiveSite
// 默认空实现）。
//
// 详情/取流（Pure Live lib/shared/platforms/tiktok/tiktok_api.dart
// 为准）：
//   ① GET https://www.tiktok.com/api-live/user/room/?aid=1988
//      &sourceType=54&staleTime=600000&uniqueId={username}
//      → data.user / data.liveRoom（status 2 = 在播，4 = 下播）；
//   ② 数字 roomId 先调 https://webcast.tiktok.com/webcast/room/info/
//      ?aid=1988&room_id={roomId} 换用户名（owner.display_id）；
//   ③ 短链跟随 3 跳以内（URLSession 自动跟随跳转，取落地页 canonical
//      链接里的 @username）；
//   ④ 流在 liveRoom.streamData / hevcStreamData 里：
//      pull_data.stream_data 是 JSON 字符串，data: {qualityKey:
//      {main: {flv, hls, sdk_params}}}，sdk_params 也是 JSON 字符串
//      （VCodec / resolution / vbitrate）。qualityId：origin / uhd_60 /
//      hd_60 / uhd / hd / sd / ld / auto（"ao" 是纯音频，跳过）；档位名
//      按 quality + resolution + codec + 协议拼。
//
// 付费房 / 订阅房 / 私密房（user.secret、liveSubOnly、paid_event）
// 一律不播：roomDetail 仍返回房间卡片（用户主动贴的链接），但
// playURLs 返回 []，搜索里这类房直接过滤掉，不列为可播房间。
// 流地址（含签名查询参数）原样保留，不拼接。
//
// 国内网络：TikTok 海外版在中国大陆基本打不开，chen 的国内真机大概率
// 看不了；本适配器只保证在能访问 TikTok 的网络下工作。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TiktokSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .tiktok
    private let http = HTTPClient.shared

    private static let origin = "https://www.tiktok.com"
    private static let webcastOrigin = "https://webcast.tiktok.com"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private static func requestHeaders(username: String?) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": origin,
            "Referer": username.map { "\(origin)/@\($0)/live" } ?? "\(origin)/live",
        ]
    }

    private static func mediaHeaders(username: String) -> [String: String] {
        [
            "user-agent": userAgent,
            "Origin": origin,
            "Referer": "\(origin)/@\(username)/live",
        ]
    }

    /// Quality key -> display name (Pure Live's _qualityName).
    private static let qualityNames: [String: String] = [
        "origin": "原画", "uhd_60": "超高清60帧", "hd_60": "高清60帧",
        "uhd": "超高清", "hd": "高清", "sd": "标清", "ld": "流畅", "auto": "自动",
    ]

    /// Quality rank, best first (Pure Live's qualitySort).
    private static func qualityRank(_ qualityID: String) -> Int {
        switch qualityID {
        case "origin": return 10_000
        case "uhd_60": return 9_000
        case "hd_60": return 8_000
        case "uhd": return 7_000
        case "hd": return 6_000
        case "sd": return 5_000
        case "ld": return 4_000
        case "auto": return 3_000
        default: return 1_000
        }
    }

    // MARK: - Lists (none: link-only platform)

    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] { [] }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { [] }

    // MARK: - Search (link / username / roomId only)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    private func search(keyword: String) async throws -> [LiveRoom] {
        guard let username = try? await resolveUsername(keyword) else { return [] }
        guard let data = try? await fetchRoom(username: username) else { return [] }
        // Not live, or restricted (private / sub-only / paid): not a
        // playable room, do not list it.
        guard data.isLive, !data.restricted else { return [] }
        return [data.room]
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let username = try await resolveUsername(roomID)
        return try await fetchRoom(username: username).room
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let username = try? await resolveUsername(room.roomID) else { return [] }
        guard let data = try? await fetchRoom(username: username),
              data.isLive, !data.restricted else { return [] }
        let headers = Self.mediaHeaders(username: username)
        var streams: [PlayStream] = []
        for info in data.streams {
            // Line ids are the protocol, per-protocol counted
            // (Pure Live's resolution(): flv, flv#2, hls, hls#2).
            var lineCounts: [String: Int] = [:]
            for (index, urlString) in info.urls.enumerated() {
                guard let url = URL(string: urlString) else { continue }
                let line: String
                if let proto = Self.protocolName(for: urlString) {
                    let count = (lineCounts[proto] ?? 0) + 1
                    lineCounts[proto] = count
                    line = count == 1 ? proto : "\(proto)#\(count)"
                } else {
                    line = "线路\(index + 1)"
                }
                streams.append(PlayStream(
                    url: url,
                    quality: info.quality,
                    line: line,
                    headers: headers
                ))
            }
        }
        guard !streams.isEmpty else {
            // Live, unrestricted, but no stream could be read: Pure
            // Live reports "live without a stream" — an empty list
            // would only surface as a vague "暂无可播放的线路".
            throw LiveSiteError.message("该直播暂无可播放的流")
        }
        return streams
    }

    /// Protocol of a pull URL by its suffix ("FLV" / "HLS"), the
    /// query string stripped first; nil when it names neither.
    static func protocolName(for urlString: String) -> String? {
        let path = urlString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? urlString
        if path.lowercased().hasSuffix(".flv") { return "FLV" }
        if path.lowercased().hasSuffix(".m3u8") { return "HLS" }
        return nil
    }

    // MARK: - Room fetch

    /// Parsed room, carrying its streams (Pure Live's TikTokRoom).
    struct TikTokRoomData {
        var room: LiveRoom
        var isLive: Bool
        var restricted: Bool
        var streams: [StreamInfo]
    }

    struct StreamInfo {
        var qualityID: String
        var codec: String
        var quality: String
        var urls: [String]
    }

    /// username -> api-live/user/room. Throws roomNotFound when the
    /// user does not exist / never went live.
    private func fetchRoom(username: String) async throws -> TikTokRoomData {
        let url = "\(Self.origin)/api-live/user/room/?aid=1988&sourceType=54&staleTime=600000&uniqueId=\(username)"
        let json = try await http.getJSON(url, headers: Self.requestHeaders(username: username))
        let code = json["statusCode"].intValue ?? -1
        if code != 0 {
            // Pure Live's room(): only 19881007 (or a message saying
            // the user does not exist) is NotFound; any other code is
            // an API change, not "no such room".
            let message = (json["message"].stringValue ?? "").lowercased()
            if code == 19881007 || message.contains("not exist") || message.contains("not_found") {
                throw LiveSiteError.roomNotFound(username)
            }
            throw LiveSiteError.invalidResponse
        }
        return try Self.roomData(fromAPI: json["data"], username: username)
    }

    /// Pure parser for the api-live/user/room data object.
    /// Testable without the network.
    static func roomData(fromAPI data: JSONValue, username: String) throws -> TikTokRoomData {
        let user = data["user"]
        let live = data["liveRoom"]
        guard !user.isNull, !live.isNull else { throw LiveSiteError.invalidResponse }
        let actual = user["uniqueId"].stringValue?.lowercased() ?? ""
        guard actual == username else { throw LiveSiteError.roomNotFound(username) }
        let status = live["status"].intValue ?? user["status"].intValue ?? -1
        let isLive = status == 2
        let restricted = isRestricted(user: user, live: live)
        let stats = live["liveRoomStats"]
        let nickname = user["nickname"].stringValue ?? ""
        let title = live["title"].stringValue ?? ""
        let room = LiveRoom(
            id: "tiktok-\(username)",
            platform: .tiktok,
            roomID: username,
            title: title.isEmpty ? nickname : title,
            anchorName: nickname,
            anchorAvatarURL: Self.imageURL(HaoText.firstNonEmpty(
                user["avatarLarger"].stringValue, user["avatarMedium"].stringValue, user["avatarThumb"].stringValue)),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(
                live["coverUrl"].stringValue, live["squareCoverImg"].stringValue)),
            categoryName: "TikTok LIVE",
            viewerCount: isLive ? (stats["userCount"].intValue ?? 0) : 0,
            isLive: isLive
        )
        return TikTokRoomData(
            room: room,
            isLive: isLive,
            restricted: restricted,
            streams: isLive && !restricted ? streams(fromLiveRoom: live) : []
        )
    }

    /// Pure Live's restrictionOf: secret / sub-only / paid event.
    /// Testable without the network.
    static func isRestricted(user: JSONValue, live: JSONValue) -> Bool {
        if live["liveSubOnly"].intValue == 1 { return true }
        if user["secret"].boolValue == true { return true }
        let paid = live["paidEvent"]
        if !paid.isNull {
            // paidEvent is an OBJECT ({paid_type: ...}), not an
            // array — the old `!paid.arrayValue.isEmpty` check was
            // false for every object, so paid LIVEs were never
            // recognised as restricted.
            return (paid["paid_type"].intValue ?? 0) > 0
        }
        return false
    }

    // MARK: - Streams

    /// Pure parser for liveRoom.streamData + hevcStreamData
    /// (Pure Live's _streams / _readContainer). One StreamInfo per
    /// (codec, quality); its urls are FLV then HLS lines, in the
    /// server's order. "ao" (audio-only) is skipped. Testable
    /// without the network.
    static func streams(fromLiveRoom live: JSONValue) -> [StreamInfo] {
        var builders: [String: StreamInfo] = [:]
        readContainer(live["streamData"], fallbackCodec: "h264", into: &builders)
        readContainer(live["hevcStreamData"], fallbackCodec: "h265", into: &builders)
        var out = Array(builders.values.filter { !$0.urls.isEmpty })
        // Pure Live's qualities() with "优先 H.264" on (the default):
        // every H.264 quality comes before every H.265 one, best
        // tier first within each codec — not the best tier overall.
        out.sort {
            let aH264 = $0.codec == "h264", bH264 = $1.codec == "h264"
            if aH264 != bH264 { return aH264 }
            let aRank = qualityRank($0.qualityID), bRank = qualityRank($1.qualityID)
            if aRank != bRank { return aRank > bRank }
            return $0.qualityID < $1.qualityID
        }
        return out
    }

    private static func readContainer(_ value: JSONValue, fallbackCodec: String, into builders: inout [String: StreamInfo]) {
        let pull = value["pull_data"]
        guard let raw = pull["stream_data"].stringValue, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = JSONValue.parse(data) else { return }
        let qualities = decoded["data"]
        guard qualities.objectValue.count <= 32 else { return }
        for (key, entry) in qualities.objectValue {
            let qualityID = key.trimmingCharacters(in: .whitespaces).lowercased()
            guard qualityID.range(of: #"^[a-z0-9_]{1,24}$"#, options: .regularExpression) != nil,
                  qualityID != "ao" else { continue }
            let main = entry["main"]
            let sdkRaw = main["sdk_params"].stringValue ?? ""
            var sdk: JSONValue = .null
            if !sdkRaw.isEmpty, let sdkData = sdkRaw.data(using: .utf8) {
                sdk = JSONValue.parse(sdkData) ?? .null
            }
            let codec = codecName(sdk["VCodec"].stringValue ?? sdk["v_codec"].stringValue ?? "", fallback: fallbackCodec)
            guard codec == "h264" || codec == "h265" else { continue }
            let resolution = resolutionName(sdk["resolution"].stringValue ?? "")
            for proto in ["flv", "hls"] {
                guard let rawURL = main[proto].stringValue, !rawURL.isEmpty,
                      isTrustedMediaURL(rawURL) else { continue }
                // One quality per (codec, tier); FLV then HLS are its
                // lines (Pure Live's TikTokStream.urls), not separate
                // qualities.
                let id = "\(codec):\(qualityID)"
                var builder = builders[id] ?? StreamInfo(
                    qualityID: qualityID,
                    codec: codec,
                    quality: displayQuality(qualityID: qualityID, resolution: resolution, codec: codec),
                    urls: []
                )
                if !builder.urls.contains(rawURL) { builder.urls.append(rawURL) }
                builders[id] = builder
            }
        }
    }

    private static func displayQuality(qualityID: String, resolution: String, codec: String) -> String {
        var parts: [String] = [qualityNames[qualityID] ?? qualityID.uppercased()]
        if !resolution.isEmpty { parts.append(resolution) }
        parts.append(codec.uppercased())
        return parts.joined(separator: " · ")
    }

    private static func codecName(_ raw: String, fallback: String) -> String {
        switch raw.lowercased() {
        case "": return fallback
        case "avc": return "h264"
        // ByteDance's own name for H.265 (Pure Live's _codec); the
        // old code dropped these tiers as an unknown codec.
        case "hevc", "bytevc1": return "h265"
        case "h264", "h265": return raw.lowercased()
        default: return ""
        }
    }

    private static func resolutionName(_ raw: String) -> String {
        let value = raw.lowercased()
        guard !value.isEmpty,
              value.range(of: #"^(?:[1-9][0-9]{1,4}x[1-9][0-9]{1,4}|[1-9][0-9]{2,4}p)$"#, options: .regularExpression) != nil else { return "" }
        return value
    }

    private static func isTrustedMediaURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        // Pure Live's _trustedRoots: the regional CDNs tiktokcdn-us
        // and tiktokcdn-eu serve real users too — the old list
        // dropped every stream served from them.
        return host == "tiktokcdn.com" || host.hasSuffix(".tiktokcdn.com")
            || host == "tiktokcdn-us.com" || host.hasSuffix(".tiktokcdn-us.com")
            || host == "tiktokcdn-eu.com" || host.hasSuffix(".tiktokcdn-eu.com")
            || host == "tiktokv.com" || host.hasSuffix(".tiktokv.com")
            || host == "byteoversea.com" || host.hasSuffix(".byteoversea.com")
    }

    // MARK: - Username resolution (Pure Live's tiktok_link.dart)

    /// Input -> username: bare username / @username, official
    /// @user/live link, /share/live/{roomId} link (via webcast
    /// room/info), or vm.tiktok.com / vt.tiktok.com short link
    /// (followed, at most 3 hops — URLSession follows the redirects
    /// and the landing page's canonical link carries the username).
    /// Throws roomNotFound when nothing resolves.
    private func resolveUsername(_ raw: String) async throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LiveSiteError.roomNotFound(raw) }
        if let username = Self.normalizeUsername(value) { return username }
        if value.hasPrefix("@"), let username = Self.normalizeUsername(String(value.dropFirst())) {
            return username
        }
        let urlString = value.hasPrefix("http://") || value.hasPrefix("https://") ? value : "https://\(value)"
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { throw LiveSiteError.roomNotFound(raw) }
        if host == "vm.tiktok.com" || host == "vt.tiktok.com" {
            return try await resolveShortLink(urlString)
        }
        guard host == "tiktok.com" || host == "www.tiktok.com" || host == "m.tiktok.com" else {
            throw LiveSiteError.roomNotFound(raw)
        }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count == 2, segments[0].lowercased() == "t" {
            // The app's newer short-link form (Pure Live's
            // TikTokLink.shortLink): www.tiktok.com/t/<code>.
            return try await resolveShortLink(urlString)
        }
        if segments.count >= 1, segments[0].hasPrefix("@") {
            guard let username = Self.normalizeUsername(String(segments[0].dropFirst())) else {
                throw LiveSiteError.roomNotFound(raw)
            }
            return username
        }
        if segments.count == 3, segments[0].lowercased() == "share", segments[1].lowercased() == "live" {
            guard let roomID = Self.normalizeRoomID(segments[2]) else {
                throw LiveSiteError.roomNotFound(raw)
            }
            return try await usernameFromRoomID(roomID)
        }
        throw LiveSiteError.roomNotFound(raw)
    }

    /// Short link -> landing page -> canonical @username.
    /// Testable without the network through canonicalUsername(in:).
    private func resolveShortLink(_ urlString: String) async throws -> String {
        let data = try await http.get(urlString, headers: Self.requestHeaders(username: nil))
        guard let html = String(data: data, encoding: .utf8),
              let username = Self.canonicalUsername(in: html) else {
            throw LiveSiteError.roomNotFound(urlString)
        }
        return username
    }

    /// `<link rel="canonical" href="https://www.tiktok.com/@user/live">`.
    /// Testable without the network.
    static func canonicalUsername(in html: String) -> String? {
        guard let canonRange = html.range(of: "canonical") else { return nil }
        let tail = html[canonRange.upperBound...]
        guard let hrefRange = tail.range(of: "href=\"") else { return nil }
        let after = tail[hrefRange.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let href = String(after[..<end])
        guard let url = URL(string: href) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        // Pure Live's parse(): a user link is /@<user> or
        // /@<user>/live only — a video link (/@<user>/video/…) is
        // no room, and the old code resolved it to the user anyway.
        guard let first = segments.first, first.hasPrefix("@"),
              segments.count == 1 || (segments.count == 2 && segments[1].lowercased() == "live") else { return nil }
        return normalizeUsername(String(first.dropFirst()))
    }

    /// webcast room/info: numeric roomId -> owner.display_id.
    private func usernameFromRoomID(_ roomID: String) async throws -> String {
        let url = "\(Self.webcastOrigin)/webcast/room/info/?aid=1988&room_id=\(roomID)"
        let json = try await http.getJSON(url, headers: Self.requestHeaders(username: nil))
        guard json["status_code"].intValue == 0 else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let data = json["data"]
        guard data["id"].stringValue == roomID,
              let username = Self.normalizeUsername(data["owner"]["display_id"].stringValue ?? "") else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return username
    }

    /// Pure Live's normalizeUsername (lowercased).
    /// Testable without the network.
    static func normalizeUsername(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.range(of: #"^[a-z0-9_](?:[a-z0-9._]{0,22}[a-z0-9_])?$"#, options: .regularExpression) != nil ? value : nil
    }

    /// 15–25 digit room id. Testable without the network.
    static func normalizeRoomID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[1-9][0-9]{14,24}$"#, options: .regularExpression) != nil ? value : nil
    }
}
