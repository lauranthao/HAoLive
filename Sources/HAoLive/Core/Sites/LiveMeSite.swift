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
//           hlsvideosource (HLS, a line of the source quality —
//           ref liveme_api.streams, 21-7: one 原画 quality holds
//           the FLV lines first, then the HLS line). Signed stream
//           URLs are used verbatim (query parameters kept).
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
                anchorAvatarURL: Self.liveMeImageURL(row["face"].stringValue),
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
        // Ref liveme_site._room: the anchor's profile and, while
        // broadcasting, the broadcast are asked in parallel.
        async let profileTask = profile(userID: mapping.userID)
        let video: VideoDetail?
        if mapping.videoID.isEmpty {
            video = nil
        } else {
            // Live (a vid is only issued for a live session): try the
            // video call WITHOUT the signer. It usually answers empty
            // (see the file header); the room is still returned with
            // profile data, just without streams.
            video = try? await videoDetail(videoID: mapping.videoID, expectedShortID: shortID)
        }
        let profile = try await profileTask
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
        return LiveRoom(
            id: "liveme-\(shortID)",
            platform: .liveme,
            roomID: shortID,
            title: video?.title ?? profile.nickname,
            anchorName: profile.nickname,
            // Ref liveme_api.withProfile: the avatar / cover fall
            // back to the profile's wherever the broadcast has none
            // (an empty broadcast field must not block the profile's).
            anchorAvatarURL: Self.imageURL(HaoText.firstNonEmpty(video?.avatar, profile.avatar)),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(video?.cover, profile.cover)),
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
        // Ref liveme_api.resolution: FLV lines first, then the HLS
        // line, in one quality; the line id is the format ("flv",
        // "hls", "flv#2", ...), not the CDN host.
        var out: [PlayStream] = []
        for stream in streams {
            for (format, urls) in [("flv", stream.flv), ("hls", stream.hls)] {
                for (index, urlString) in urls.enumerated() {
                    guard let url = URL(string: urlString) else { continue }
                    let line = index == 0 ? format : "\(format)#\(index + 1)"
                    out.append(PlayStream(url: url, quality: stream.qualityName, line: line, headers: headers))
                }
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
    /// The media URLs of one quality (ref liveme_api.LiveMeStream,
    /// 21-7): `source` (原画) carries the FLV lines first, then the
    /// HLS line; `smooth` (流畅) carries FLV lines only.
    struct LiveMeStream {
        var qualityID: String
        var flv: [String]
        var hls: [String]
        /// Every URL, in line order: FLV lines first, then HLS.
        var urls: [String] { flv + hls }
        var qualityName: String {
            switch qualityID {
            case "source": return "原画"
            case "smooth": return "流畅"
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
            avatar: Self.liveMeImageURL(info["big_face"].stringValue, info["face"].stringValue)?.absoluteString ?? "",
            cover: Self.liveMeImageURL(info["big_cover"].stringValue, info["cover"].stringValue)?.absoluteString ?? "",
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
        let rawTitle = video["title"].stringValue ?? ""
        // Ref liveme_api.videoSnapshot: an empty title or one of
        // the app's placeholder titles (defaultTitles) is the
        // anchor's name — "Click for fun!" is not a real title.
        let title = rawTitle.isEmpty || Self.defaultTitles.contains(rawTitle) ? nickname : rawTitle
        let streams = (isLive && includeMedia) ? streams(fromVideoInfo: video) : []
        return LiveRoom(
            id: "liveme-\(shortID)",
            platform: .liveme,
            roomID: shortID,
            title: title,
            anchorName: nickname,
            anchorAvatarURL: Self.liveMeImageURL(video["uface"].stringValue, video["face"].stringValue),
            coverURL: Self.liveMeImageURL(video["videocapture"].stringValue, video["smallcover"].stringValue),
            categoryName: video["countryCode"].stringValue ?? video["country_code"].stringValue,
            viewerCount: isLive ? (video["playnumber"].intValue ?? 0) : 0,
            isLive: isLive,
            playDataJSON: streamsJSON(streams)
        )
    }

    /// Private (ispvt==1) / paid (livebptype==7 / "paid broadcast").
    /// Ref liveme_api.restrictionOf/isPaidLabel: hot_label_v2
    /// arrives as JSON TEXT — it must be parsed before reading
    /// `text`. The old code compared the raw JSON text itself, so
    /// a paid room labelled {"text":"Paid broadcast"} was missed.
    static func isRestricted(_ video: JSONValue) -> Bool {
        if video["ispvt"].intValue == 1 { return true }
        if video["livebptype"].intValue == 7 { return true }
        return isPaidLabel(video["hot_label_v2"])
    }

    static func isPaidLabel(_ label: JSONValue) -> Bool {
        if let text = label.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let parsed = JSONValue.parse(data) else { return false }
            return parsed["text"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "paid broadcast"
        }
        return label["text"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "paid broadcast"
    }

    /// The app's placeholder broadcast titles (ref
    /// liveme_api.defaultTitles): a broadcast titled like this has
    /// no title of its own and is named by the anchor.
    static let defaultTitles: Set<String> = [
        "Click for fun!",
        "¡Haz clic para divertirte!",
        "Clique e divirta-se!",
        "Нажмите и веселитесь!",
        "انقر للمتعة!",
    ]

    /// An image URL the way ref liveme_api.image keeps one: http(s),
    /// no user info or fragment, on esxscloud.com / liveme.com /
    /// linkv.fun (or a subdomain), made https; the first usable
    /// candidate wins, so a dead first field falls back to the next
    /// (ref _firstImage, 21-2).
    static func liveMeImageURL(_ values: String?...) -> URL? {
        for raw in values {
            guard let raw, !raw.isEmpty,
                  let url = Self.imageURL(raw),
                  let host = url.host?.lowercased(),
                  host == "esxscloud.com" || host.hasSuffix(".esxscloud.com")
                    || host == "liveme.com" || host.hasSuffix(".liveme.com")
                    || host == "linkv.fun" || host.hasSuffix(".linkv.fun") else { continue }
            return url
        }
        return nil
    }

    /// The media of a live `video_info` (ref liveme_api.streams,
    /// 21-7): `source` with the FLV URLs of `videosource` and
    /// `videosourcemore` and the HLS URL of `hlsvideosource`;
    /// `smooth` with the FLV URLs of `smallsource` and
    /// `smallsourcemore`. A quality without one is left out.
    static func streams(fromVideoInfo video: JSONValue) -> [LiveMeStream] {
        func urls(_ values: [JSONValue], proto: String) -> [String] {
            var out: [String] = []
            var seen = Set<String>()
            for value in values {
                for raw in flattenURLs(value) {
                    guard let uri = mediaURL(raw, protocol: proto), seen.insert(uri).inserted else { continue }
                    out.append(uri)
                }
            }
            return out
        }
        var out: [LiveMeStream] = []
        let source = LiveMeStream(
            qualityID: "source",
            flv: urls([video["videosource"], video["videosourcemore"]], proto: "flv"),
            hls: urls([video["hlsvideosource"]], proto: "hls")
        )
        if !source.urls.isEmpty { out.append(source) }
        let smooth = LiveMeStream(
            qualityID: "smooth",
            flv: urls([video["smallsource"], video["smallsourcemore"]], proto: "flv"),
            hls: []
        )
        if !smooth.urls.isEmpty { out.append(smooth) }
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
    /// Ref liveme_api.mediaUrl (21-6): on a trusted host the URL
    /// is made https; on any other host (or with an explicit port)
    /// it is kept as written — never dropped. The old code returned
    /// nil for those, silently losing lines the reference plays.
    static func mediaURL(_ raw: String, protocol proto: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.fragment == nil else { return nil }
        let path = url.path.lowercased()
        guard proto == "flv" ? path.hasSuffix(".flv") : path.hasSuffix(".m3u8") else { return nil }
        guard (host == "linkv.fun" || host.hasSuffix(".linkv.fun")
            || host == "emolm.com" || host.hasSuffix(".emolm.com")
            || host == "liveme.com" || host.hasSuffix(".liveme.com")),
              url.port == nil else { return raw }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url?.absoluteString
    }

    static func streamsJSON(_ streams: [LiveMeStream]) -> String? {
        guard !streams.isEmpty else { return nil }
        let items = streams.map { stream in
            let flv = stream.flv.map { "\"\($0)\"" }.joined(separator: ",")
            let hls = stream.hls.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"qualityId\":\"\(stream.qualityID)\",\"flv\":[\(flv)],\"hls\":[\(hls)]}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    static func streams(fromStoredJSON json: JSONValue) -> [LiveMeStream] {
        // New shape: {"qualityId","flv":[],"hls":[]}. The build 11
        // shape ({"qualityId","protocol","urls":[]}) is still read,
        // so rooms saved before this change keep playing:
        // source-flv -> source/flv, smooth-flv -> smooth/flv,
        // hls -> source/hls.
        var merged: [String: LiveMeStream] = [:]
        var order: [String] = []
        func ensure(_ qualityID: String) {
            if merged[qualityID] == nil {
                merged[qualityID] = LiveMeStream(qualityID: qualityID, flv: [], hls: [])
                order.append(qualityID)
            }
        }
        for item in json.arrayValue {
            guard let qualityID = item["qualityId"].stringValue else { continue }
            if item["protocol"].stringValue == nil {
                ensure(qualityID)
                var stream = merged[qualityID]!
                stream.flv += item["flv"].arrayValue.compactMap { $0.stringValue }
                stream.hls += item["hls"].arrayValue.compactMap { $0.stringValue }
                merged[qualityID] = stream
            } else if let proto = item["protocol"].stringValue {
                let urls = item["urls"].arrayValue.compactMap { $0.stringValue }
                guard !urls.isEmpty else { continue }
                let target: String
                let isFlv: Bool
                if qualityID == "source-flv" { target = "source"; isFlv = true }
                else if qualityID == "smooth-flv" { target = "smooth"; isFlv = true }
                else if qualityID == "hls" { target = "source"; isFlv = false }
                else { target = qualityID; isFlv = proto == "flv" }
                ensure(target)
                var stream = merged[target]!
                if isFlv { stream.flv += urls } else { stream.hls += urls }
                merged[target] = stream
            }
        }
        return order.compactMap { merged[$0] }.filter { !$0.urls.isEmpty }
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
    /// Ref LiveMeLink.parse: an optional locale segment first
    /// (`us`, `zh-tw`, ...) is skipped before the path is read.
    static func parseShortID(_ raw: String) -> String? {
        if let id = normalizeShortID(raw) { return id }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), host == "liveme.com" || host == "www.liveme.com" else { return nil }
        let segments = stripLocale(url.pathComponents.filter { $0 != "/" })
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
        let segments = stripLocale(url.pathComponents.filter { $0 != "/" })
        if segments.count == 2, segments[0].lowercased() == "u" {
            return normalizeLongID(segments[1])
        }
        return nil
    }

    /// Ref LiveMeLink.parse: drop a leading locale segment
    /// (`us`, `zh-tw`) so `/us/livehot/streaming/<id>` and
    /// `/us/u/<id>` resolve like the bare paths.
    static func stripLocale(_ segments: [String]) -> [String] {
        guard let first = segments.first,
              first.range(of: #"^[a-zA-Z]{2}(?:-[a-zA-Z]{2,4})?$"#, options: .regularExpression) != nil else { return segments }
        return Array(segments.dropFirst())
    }
}
