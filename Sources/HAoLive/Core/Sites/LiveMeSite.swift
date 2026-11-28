// LiveMeSite.swift
// HAo Live — LiveMe adapter (anonymous guest parameters, no login).
//
// SIGNER NOTE — the reference's LiveMeSigner embeds a fixed signing
// secret, so it is NOT copied here (same red line as Baidu's feed
// secret). Consequences, verified live from this VM 2026-11-28:
//   * directory / search / short-id mapping / profile are UNSIGNED
//     in the reference too, and work as implemented below.
//   * the video-detail call (POST /live/queryinfosimple) is the
//     ONLY signed call. This adapter retries it WITHOUT a signature
//     (plain guest fields + a locally generated random `vali`);
//     the server answered it with an empty body from this VM, i.e.
//     the unsigned call does not return streams.
//   * the directory list itself already carries the streams
//     (videosource / smallsource / hlsvideosource), so rooms opened
//     from the list DO play: their streams ride in
//     LiveRoom.playDataJSON. A room opened only by short id (search
//     direct / link) has no playable stream until the signed call
//     has an alternative — playURLs then returns [] honestly.
// Private rooms (ispvt==1) and paid rooms (livebptype==7 or a
// "paid broadcast" label) are skipped, never listed as playable.
//
// Endpoints (verified live from this VM 2026-11-28):
//   list    GET lvapi.liveme.com/live/featurelist?countryCode=GLOBAL
//           &page_index=&page_size=&pid=3&posid=3002&h5=1
//           -> data.video_info[]; ushortid (short id) is the room
//           key — cards without one are skipped.
//   search  GET live.liveme.com/search/searchKeyword (+ guest
//           params alias=liveme&os=web&h5=1&thirdchannel=6&_time=)
//           -> data.data_info[] (short_id/nickname/face/is_live).
//   detail  GET /liveme_ent/v1/user/uid_vid_by_short_id?short_id=
//           (+ guest params) -> uid/vid; then GET /user/getinfo
//           ?userid= (profile). vid empty = offline.
//   streams videosource/videosourcemore (source FLV),
//           smallsource/smallsourcemore (smooth FLV),
//           hlsvideosource (HLS). Signed stream URLs are used
//           verbatim (query parameters kept).
// Danmaku: none (no danmaku file in the reference).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LiveMeSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .liveme
    private let http = HTTPClient.shared

    private static let apiBase = "https://live.liveme.com"
    private static let directoryBase = "https://lvapi.liveme.com"

    private static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private static func requestHeaders(shortID: String? = nil) -> [String: String] {
        [
            "User-Agent": desktopUA,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": "https://www.liveme.com",
            "Referer": shortID.map { "https://www.liveme.com/livehot/streaming/\($0)" } ?? "https://www.liveme.com/livehot",
        ]
    }

    /// Guest query parameters (no signature, no login).
    private static func guestQuery() -> [String: String] {
        [
            "alias": "liveme",
            "tongdun_black_box": "1",
            "os": "web",
            "_time": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "h5": "1",
            "thirdchannel": "6",
        ]
    }

    private static func url(base: String, path: String, query: [String: String]) -> String {
        var components = URLComponents(string: base + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url?.absoluteString ?? base + path
    }

    // MARK: - Lists (no category tree)

    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let query: [String: String] = [
            "countryCode": "GLOBAL",
            "page_index": "\(page)",
            "page_size": "20",
            "pid": "3",
            "posid": "3002",
            "h5": "1",
        ]
        let json = try await http.getJSON(Self.url(base: Self.directoryBase, path: "/live/featurelist", query: query), headers: Self.requestHeaders())
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let data = json["data"]
        var seen = Set<String>()
        return data["video_info"].arrayValue.compactMap { item in
            guard let room = Self.room(fromVideoInfo: item, includeMedia: true),
                  seen.insert(room.roomID).inserted else { return nil }
            return room
        }
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { [] }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let raw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, page >= 1 else { return [] }
        // Link / short-id / user-id / video-id direct.
        if let shortID = Self.parseShortID(raw) {
            guard page == 1 else { return [] }
            do {
                return [try await roomDetail(roomID: shortID)]
            } catch LiveSiteError.roomNotFound {
                return []
            }
        }
        if let userID = Self.parseUserID(raw) {
            guard page == 1 else { return [] }
            // userId -> profile (unsigned) -> short id -> detail.
            if let shortID = try? await profileShortID(userID: userID) {
                do {
                    return [try await roomDetail(roomID: shortID)]
                } catch LiveSiteError.roomNotFound {
                    return []
                }
            }
            return []
        }
        var query = Self.guestQuery()
        query["type"] = "1"
        query["page"] = "\(page)"
        query["pageSize"] = "30"
        query["keyword"] = raw
        query["tuid"] = ""
        query["uid"] = ""
        query["token"] = ""
        query["androidid"] = ""
        let json = try await http.getJSON(Self.url(base: Self.apiBase, path: "/search/searchKeyword", query: query), headers: Self.requestHeaders())
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        var seen = Set<String>()
        return json["data"]["data_info"].arrayValue.compactMap { row in
            guard let shortID = Self.normalizeShortID(row["short_id"].stringValue ?? ""),
                  seen.insert(shortID).inserted else { return nil }
            let nickname = HaoText.firstNonEmpty(row["nickname"].stringValue, row["uname"].stringValue) ?? ""
            let isLive = row["is_live"].intValue == 1
            return LiveRoom(
                id: "liveme-\(shortID)",
                platform: .liveme,
                roomID: shortID,
                title: nickname,
                anchorName: nickname,
                anchorAvatarURL: Self.imageURL(row["face"].stringValue),
                coverURL: nil,
                categoryName: row["countryCode"].stringValue,
                viewerCount: 0,
                isLive: isLive
            )
        }
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: page)
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let shortID = Self.parseShortID(roomID) else { throw LiveSiteError.roomNotFound(roomID) }
        let mapping = try await shortIDMapping(shortID: shortID)
        let profile = try await profile(userID: mapping.userID)
        guard profile.shortID == shortID, profile.userID == mapping.userID else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        guard !mapping.videoID.isEmpty else {
            // Offline: profile only.
            return LiveRoom(
                id: "liveme-\(shortID)",
                platform: .liveme,
                roomID: shortID,
                title: profile.nickname,
                anchorName: profile.nickname,
                anchorAvatarURL: Self.imageURL(profile.avatar),
                coverURL: Self.imageURL(profile.cover),
                categoryName: profile.countryCode.isEmpty ? nil : profile.countryCode,
                viewerCount: 0,
                isLive: false
            )
        }
        // Live (a vid is only issued for a live session): try the
        // video call WITHOUT the signer. It usually answers empty
        // (see the file header); the room is still returned with
        // profile data, just without streams.
        let video = try? await videoDetail(videoID: mapping.videoID, expectedShortID: shortID)
        return LiveRoom(
            id: "liveme-\(shortID)",
            platform: .liveme,
            roomID: shortID,
            title: video?.title ?? profile.nickname,
            anchorName: profile.nickname,
            anchorAvatarURL: Self.imageURL(video?.avatar ?? profile.avatar),
            coverURL: Self.imageURL(video?.cover ?? profile.cover),
            categoryName: profile.countryCode.isEmpty ? nil : profile.countryCode,
            viewerCount: video?.viewerCount ?? 0,
            isLive: true,
            playDataJSON: video.flatMap { Self.streamsJSON($0.streams) }
        )
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let shortID = Self.parseShortID(room.roomID) else { return [] }
        var streams: [LiveMeStream] = []
        if let payload = room.playDataJSON,
           let data = payload.data(using: .utf8),
           let json = JSONValue.parse(data) {
            streams = Self.streams(fromStoredJSON: json)
        }
        if streams.isEmpty {
            // Re-fetch: a list room carries streams, a direct room
            // tries the unsigned video call once more.
            if let detail = try? await roomDetail(roomID: shortID),
               let payload = detail.playDataJSON,
               let data = payload.data(using: .utf8),
               let json = JSONValue.parse(data) {
                streams = Self.streams(fromStoredJSON: json)
            }
        }
        let headers = [
            "User-Agent": Self.desktopUA,
            "Origin": "https://www.liveme.com",
            "Referer": "https://www.liveme.com/livehot/streaming/\(shortID)",
        ]
        var out: [PlayStream] = []
        for stream in streams {
            for urlString in stream.urls {
                guard let url = URL(string: urlString) else { continue }
                out.append(PlayStream(url: url, quality: stream.qualityName, line: url.host ?? "主线路", headers: headers))
            }
        }
        return out
    }

    // MARK: - Unsigned API calls

    private struct Mapping { var userID: String; var videoID: String }
    private struct Profile {
        var shortID: String; var userID: String; var nickname: String
        var avatar: String; var cover: String; var bio: String; var countryCode: String
    }
    struct LiveMeStream {
        var qualityID: String; var proto: String; var urls: [String]
        var qualityName: String {
            switch qualityID {
            case "source-flv": return "原画·FLV"
            case "smooth-flv": return "流畅·FLV"
            case "hls": return "HLS"
            default: return qualityID
            }
        }
    }
    private struct VideoDetail {
        var title: String; var avatar: String; var cover: String; var viewerCount: Int
        var streams: [LiveMeStream]
    }

    private func shortIDMapping(shortID: String) async throws -> Mapping {
        var query = Self.guestQuery()
        query["short_id"] = shortID
        let json = try await http.getJSON(Self.url(base: Self.apiBase, path: "/liveme_ent/v1/user/uid_vid_by_short_id", query: query), headers: Self.requestHeaders(shortID: shortID))
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let data = json["data"]
        guard let userID = Self.normalizeLongID(data["uid"].stringValue ?? "") else {
            throw LiveSiteError.roomNotFound(shortID)
        }
        let videoID = data["vid"].stringValue ?? ""
        return Mapping(userID: userID, videoID: videoID.isEmpty ? "" : (Self.normalizeLongID(videoID) ?? ""))
    }

    private func profile(userID: String) async throws -> Profile {
        var query = Self.guestQuery()
        query["userid"] = userID
        let json = try await http.getJSON(Self.url(base: Self.apiBase, path: "/user/getinfo", query: query), headers: Self.requestHeaders())
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let user = json["data"]["user"]
        let info = user["user_info"]
        let actual = Self.normalizeLongID(info["uid"].stringValue ?? info["userid"].stringValue ?? info["cm_openid"].stringValue ?? "")
        guard actual == userID else { throw LiveSiteError.invalidResponse }
        let counts = user["count_info"]
        _ = counts
        return Profile(
            shortID: Self.normalizeShortID(info["short_id"].stringValue ?? "") ?? "",
            userID: userID,
            nickname: HaoText.firstNonEmpty(info["nickname"].stringValue, info["uname"].stringValue) ?? "",
            avatar: HaoText.firstNonEmpty(info["big_face"].stringValue, info["face"].stringValue) ?? "",
            cover: HaoText.firstNonEmpty(info["big_cover"].stringValue, info["cover"].stringValue) ?? "",
            bio: info["usign"].stringValue ?? "",
            countryCode: info["countryCode"].stringValue ?? ""
        )
    }

    private func profileShortID(userID: String) async throws -> String? {
        let profile = try await profile(userID: userID)
        return profile.shortID.isEmpty ? nil : profile.shortID
    }

    /// Unsigned retry of POST /live/queryinfosimple: guest fields
    /// only, no `lm-s-sign` header, `vali` generated locally (random
    /// text, no secret). The server answered this with an empty body
    /// from the VM (2026-11-28) — streams stay empty when it fails.
    private func videoDetail(videoID: String, expectedShortID: String) async throws -> VideoDetail {
        let query: [String: String] = ["alias": "liveme", "tongdun_black_box": "1", "os": "web"]
        let fields: [String: String] = [
            "_time": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "thirdchannel": "6",
            "videoid": videoID,
            "area": "en",
            "vali": Self.randomVali(),
        ]
        let json = try await http.postFormJSON(
            Self.url(base: Self.apiBase, path: "/live/queryinfosimple", query: query),
            fields: fields,
            headers: Self.requestHeaders(shortID: expectedShortID)
        )
        guard json["status"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        guard let room = Self.room(fromVideoInfo: json["data"]["video_info"], includeMedia: true, expectedShortID: expectedShortID, expectedVideoID: videoID) else {
            throw LiveSiteError.invalidResponse
        }
        return VideoDetail(
            title: room.title, avatar: room.anchorAvatarURL?.absoluteString ?? "",
            cover: room.coverURL?.absoluteString ?? "", viewerCount: room.viewerCount,
            streams: Self.streams(fromVideoInfo: json["data"]["video_info"])
        )
    }

    /// `vali`: 4 random chars + "l" + 4 + "m" + 5, from the public
    /// alphabet — random text, no secret involved.
    private static func randomVali() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678")
        func text(_ count: Int) -> String {
            String((0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        }
        return "\(text(4))l\(text(4))m\(text(5))"
    }

    // MARK: - Mapping helpers

    /// Pure parser for a video_info item (directory / video detail).
    /// Returns nil for cards without a short id or for private/paid
    /// rooms (never listed as playable).
    static func room(fromVideoInfo video: JSONValue, includeMedia: Bool, expectedShortID: String? = nil, expectedVideoID: String? = nil) -> LiveRoom? {
        guard let shortID = normalizeShortID(video["ushortid"].stringValue ?? video["short_id"].stringValue ?? "") else { return nil }
        if let expectedShortID, shortID != expectedShortID { return nil }
        let rawVideoID = video["vid"].stringValue ?? video["vdoid"].stringValue ?? ""
        let videoID = rawVideoID.isEmpty ? "" : rawVideoID
        if let expectedVideoID, videoID != expectedVideoID { return nil }
        if isRestricted(video) { return nil }
        let online = video["online"].intValue
        let status = video["status"].intValue
        let roomState = video["roomstate"].intValue
        let isLive = online == 1 && status == 0 && roomState == 0
        let nickname = HaoText.firstNonEmpty(video["uname"].stringValue, video["nickname"].stringValue) ?? ""
        let title = video["title"].stringValue ?? ""
        let streams = (isLive && includeMedia) ? streams(fromVideoInfo: video) : []
        return LiveRoom(
            id: "liveme-\(shortID)",
            platform: .liveme,
            roomID: shortID,
            title: title.isEmpty ? nickname : title,
            anchorName: nickname,
            anchorAvatarURL: Self.imageURL(HaoText.firstNonEmpty(video["uface"].stringValue, video["face"].stringValue)),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(video["videocapture"].stringValue, video["smallcover"].stringValue)),
            categoryName: video["countryCode"].stringValue ?? video["country_code"].stringValue,
            viewerCount: isLive ? (video["playnumber"].intValue ?? 0) : 0,
            isLive: isLive,
            playDataJSON: streamsJSON(streams)
        )
    }

    /// Private (ispvt==1) / paid (livebptype==7 / "paid broadcast").
    static func isRestricted(_ video: JSONValue) -> Bool {
        if video["ispvt"].intValue == 1 { return true }
        if video["livebptype"].intValue == 7 { return true }
        let label = video["hot_label_v2"]
        let text: String
        if !label.isNull, label.objectValue["text"] != nil {
            text = label["text"].stringValue ?? ""
        } else {
            text = label.stringValue ?? ""
        }
        return text.lowercased() == "paid broadcast"
    }

    static func streams(fromVideoInfo video: JSONValue) -> [LiveMeStream] {
        var out: [LiveMeStream] = []
        func add(_ qualityID: String, proto: String, values: [JSONValue]) {
            var urls: [String] = []
            var seen = Set<String>()
            for value in values {
                for raw in flattenURLs(value) {
                    guard let uri = mediaURL(raw, protocol: proto), seen.insert(uri).inserted else { continue }
                    urls.append(uri)
                }
            }
            if !urls.isEmpty { out.append(LiveMeStream(qualityID: qualityID, proto: proto, urls: urls)) }
        }
        add("source-flv", proto: "flv", values: [video["videosource"], video["videosourcemore"]])
        add("smooth-flv", proto: "flv", values: [video["smallsource"], video["smallsourcemore"]])
        add("hls", proto: "hls", values: [video["hlsvideosource"]])
        return out
    }

    /// A stream URL may be a plain URL, a JSON-encoded string, or a
    /// JSON list/map of URLs (depth-capped).
    static func flattenURLs(_ value: JSONValue, depth: Int = 0) -> [String] {
        guard depth <= 3 else { return [] }
        if let text = value.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return [trimmed] }
            if (trimmed.hasPrefix("[") || trimmed.hasPrefix("{")),
               let data = trimmed.data(using: .utf8),
               let parsed = JSONValue.parse(data) {
                return flattenURLs(parsed, depth: depth + 1)
            }
            return []
        }
        if !value.arrayValue.isEmpty { return value.arrayValue.flatMap { flattenURLs($0, depth: depth + 1) } }
        let object = value.objectValue
        if !object.isEmpty { return object.values.flatMap { flattenURLs($0, depth: depth + 1) } }
        return []
    }

    /// Stream URLs: https only, trusted LiveMe hosts, .flv / .m3u8
    /// by protocol. Query parameters (wsSecret etc.) kept verbatim.
    static func mediaURL(_ raw: String, protocol proto: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              (host == "linkv.fun" || host.hasSuffix(".linkv.fun")
                || host == "emolm.com" || host.hasSuffix(".emolm.com")
                || host == "liveme.com" || host.hasSuffix(".liveme.com")),
              url.user == nil, url.fragment == nil else { return nil }
        let path = url.path.lowercased()
        guard proto == "flv" ? path.hasSuffix(".flv") : path.hasSuffix(".m3u8") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url?.absoluteString
    }

    static func streamsJSON(_ streams: [LiveMeStream]) -> String? {
        guard !streams.isEmpty else { return nil }
        let items = streams.map { stream in
            let urls = stream.urls.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"qualityId\":\"\(stream.qualityID)\",\"protocol\":\"\(stream.proto)\",\"urls\":[\(urls)]}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    static func streams(fromStoredJSON json: JSONValue) -> [LiveMeStream] {
        json.arrayValue.compactMap { item in
            guard let qualityID = item["qualityId"].stringValue,
                  let proto = item["protocol"].stringValue else { return nil }
            let urls = item["urls"].arrayValue.compactMap { $0.stringValue }
            guard !urls.isEmpty else { return nil }
            return LiveMeStream(qualityID: qualityID, proto: proto, urls: urls)
        }
    }

    /// Short id: 5-12 digits, first digit non-zero.
    static func normalizeShortID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[1-9][0-9]{4,11}$"#, options: .regularExpression) != nil ? value : nil
    }

    /// Long id (user / video): 13-24 digits, first digit non-zero.
    static func normalizeLongID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[1-9][0-9]{12,23}$"#, options: .regularExpression) != nil ? value : nil
    }

    /// Bare short id, or a liveme.com link:
    /// /livehot/streaming/{short} (other link forms resolve to a
    /// user/video id and are handled by parseUserID / roomDetail).
    static func parseShortID(_ raw: String) -> String? {
        if let id = normalizeShortID(raw) { return id }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), host == "liveme.com" || host == "www.liveme.com" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count >= 3, segments[segments.count - 3].lowercased() == "livehot",
           segments[segments.count - 2].lowercased() == "streaming" {
            return normalizeShortID(segments[segments.count - 1])
        }
        return nil
    }

    /// Bare long user id, or a liveme.com/u/{userId} link.
    static func parseUserID(_ raw: String) -> String? {
        if let id = normalizeLongID(raw) { return id }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), host == "liveme.com" || host == "www.liveme.com" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count == 2, segments[0].lowercased() == "u" {
            return normalizeLongID(segments[1])
        }
        return nil
    }
}
