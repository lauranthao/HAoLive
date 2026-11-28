// SteamSite.swift
// HAo Live — Steam Broadcast adapter (anonymous, no login).
//
// NOTE on the stream format: the brief said getbroadcastmpd
// returns a DASH MPD, but the reference (steam_broadcast_api.dart,
// current version) reads `hls_url` from that same endpoint and
// validates it as an HLS master playlist (#EXTM3U with
// #EXT-X-STREAM-INF variants). This adapter follows the reference:
// one "原画" HLS master stream. mpv plays HLS; no DASH handling.
//   list    GET steamcommunity.com/apps/allcontenthome
//           ?l=english&browsefilter=trend&appHubSubSection=13
//           &forceanon=1&p=&broadcastsoffset=&numperpage=10
//           (HTML, .Broadcast_Card cards; forceanon=1 is the key
//           anonymous parameter). Verified live from this VM
//           2026-11-28: HTTP 200, cards with /broadcast/watch/
//           links present.
//   detail  GET /broadcast/watch/{steamId} (watch page: parse
//           #application_config data-broadcastsinfo JSON + og:title)
//           -> GET /broadcast/getbroadcastmpd/?broadcastid=0
//           &steamid={id}&viewertoken=0&sessionid=
//           -> {success ("ready" = live), hls_url, num_viewers,
//           broadcastid, title, is_replay}. The master playlist is
//           fetched and validated before playback.
// Search: steamId/link direct + local filter of the page-1 list.
// Danmaku: SteamBroadcastDanmaku (getchatinfo window polling).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SteamSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .steambroadcast
    private let http = HTTPClient.shared

    private static let origin = "https://steamcommunity.com"
    private static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private static let directoryHeaders: [String: String] = [
        "User-Agent": desktopUA,
        "Accept": "text/html, */*; q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": "\(origin)/?subsection=broadcasts",
        "X-Requested-With": "XMLHttpRequest",
    ]

    private static func roomHeaders(steamID: String, json: Bool = false) -> [String: String] {
        [
            "User-Agent": desktopUA,
            "Accept": json ? "application/json, text/javascript, */*; q=0.8" : "text/html,application/xhtml+xml,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "\(origin)/broadcast/watch/\(steamID)",
        ]
    }

    // MARK: - Lists (no category tree)

    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let url = "\(Self.origin)/apps/allcontenthome?l=english&browsefilter=trend&appHubSubSection=13&forceanon=1&p=\(page)&broadcastsoffset=\((page - 1) * 10)&numperpage=10"
        let data = try await http.get(url, headers: Self.directoryHeaders)
        guard let html = String(data: data, encoding: .utf8) else { throw LiveSiteError.invalidResponse }
        return Self.rooms(fromDirectoryHTML: html)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { [] }

    // MARK: - Search (steamId/link direct + local filter)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let raw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, page >= 1 else { return [] }
        if let steamID = Self.parseSteamID(raw) {
            guard page == 1 else { return [] }
            do {
                return [try await roomDetail(roomID: steamID)]
            } catch LiveSiteError.roomNotFound {
                return []
            }
        }
        let query = raw.lowercased()
        let rooms = try await recommendRooms(page: page)
        return rooms.filter {
            $0.anchorName.lowercased().contains(query)
                || $0.title.lowercased().contains(query)
                || ($0.categoryName?.lowercased().contains(query) == true)
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
        guard let steamID = Self.parseSteamID(roomID) else { throw LiveSiteError.roomNotFound(roomID) }
        let watchData = try await http.get("\(Self.origin)/broadcast/watch/\(steamID)", headers: Self.roomHeaders(steamID: steamID))
        guard let watchHTML = String(data: watchData, encoding: .utf8) else { throw LiveSiteError.invalidResponse }
        let broadcaster = Self.broadcaster(fromWatchHTML: watchHTML, steamID: steamID)
        let endpoint = "\(Self.origin)/broadcast/getbroadcastmpd/?broadcastid=0&steamid=\(steamID)&viewertoken=0&sessionid="
        let json = try await http.getJSON(endpoint, headers: Self.roomHeaders(steamID: steamID, json: true))
        guard let parsed = Self.broadcast(fromJSON: json, steamID: steamID, broadcaster: broadcaster) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return LiveRoom(
            id: "steambroadcast-\(steamID)",
            platform: .steambroadcast,
            roomID: steamID,
            title: parsed.title,
            anchorName: broadcaster,
            anchorAvatarURL: nil,
            coverURL: nil,
            categoryName: "Steam Community",
            viewerCount: parsed.viewerCount ?? 0,
            isLive: parsed.isLive,
            playDataJSON: Self.playDataJSON(master: parsed.master, broadcastID: parsed.broadcastID)
        )
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let steamID = Self.parseSteamID(room.roomID) else { return [] }
        var master: String?
        if let payload = room.playDataJSON,
           let data = payload.data(using: .utf8),
           let json = JSONValue.parse(data) {
            master = json["master"].stringValue
        }
        if master == nil {
            if let detail = try? await roomDetail(roomID: steamID),
               let payload = detail.playDataJSON,
               let data = payload.data(using: .utf8),
               let json = JSONValue.parse(data) {
                master = json["master"].stringValue
            }
        }
        guard let master, let url = URL(string: master) else { return [] }
        // Validate the master playlist before handing it to the player.
        let playlistData = try? await http.get(master, headers: mediaHeaders(steamID: steamID))
        if let playlistData, let playlist = String(data: playlistData, encoding: .utf8) {
            guard Self.isValidMaster(playlist, steamID: steamID, masterHost: url.host ?? "") else { return [] }
        }
        return [PlayStream(
            url: url,
            quality: "原画",
            line: "Steam",
            headers: mediaHeaders(steamID: steamID)
        )]
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return SteamDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    private func mediaHeaders(steamID: String) -> [String: String] {
        [
            "User-Agent": Self.desktopUA,
            "Origin": Self.origin,
            "Referer": "\(Self.origin)/broadcast/watch/\(steamID)",
        ]
    }

    // MARK: - Mapping helpers

    struct BroadcastInfo {
        var title: String
        var viewerCount: Int?
        var isLive: Bool
        var master: String?
        var broadcastID: String
        var restricted: Bool
    }

    /// Pure parser for the directory HTML: one room per
    /// .Broadcast_Card block. Testable without the network.
    static func rooms(fromDirectoryHTML html: String) -> [LiveRoom] {
        var out: [LiveRoom] = []
        var seen = Set<String>()
        // Split on the card class; each chunk after the first is one card.
        let chunks = html.components(separatedBy: "Broadcast_Card")
        for chunk in chunks.dropFirst() {
            guard let steamID = firstCapture(#"/broadcast/watch/(7656119\d{10})"#, in: chunk),
                  seen.insert(steamID).inserted else { continue }
            // NOTE: match class="…" exactly — the bare prefix also
            // matches …TypeContainer / …PreviewImageBorder, whose
            // inner text is only whitespace.
            let game = clean(firstCapture(#"class="apphub_CardContentTitle[^"]*">([^<]+)<"#, in: chunk)) ?? ""
            let contentType = clean(firstCapture(#"class="apphub_CardContentType">([^<]+)<"#, in: chunk)) ?? ""
            var title = contentType.isEmpty ? game : contentType
            if let range = title.range(of: #":\s*Broadcast\s*$"#, options: .regularExpression) {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let broadcaster = clean(firstCapture(#"class="apphub_CardContentAuthorName[^"]*">(?:<a[^>]*>)?([^<]+)"#, in: chunk)) ?? steamID
            let cover = firstCapture(#"class="apphub_CardContentPreviewImage"[^>]*src="([^"]+)""#, in: chunk)
            let viewersText = firstCapture(#"class="apphub_CardContentViewers[^"]*">([^<]+)<"#, in: chunk) ?? ""
            out.append(LiveRoom(
                id: "steambroadcast-\(steamID)",
                platform: .steambroadcast,
                roomID: steamID,
                title: title.isEmpty ? game : title,
                anchorName: broadcaster,
                anchorAvatarURL: nil,
                coverURL: Self.imageURL(cover),
                categoryName: game.isEmpty ? nil : game,
                viewerCount: parseViewerCount(viewersText) ?? 0,
                isLive: true
            ))
        }
        return out
    }

    static func parseViewerCount(_ text: String) -> Int? {
        guard let match = firstCapture(#"^\s*([0-9][0-9,._\s]*)\s+viewers?\b"#, in: text, options: [.caseInsensitive]) else { return nil }
        let digits = match.filter { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 12 else { return nil }
        return Int(digits)
    }

    /// Trim + collapse inner whitespace runs (card HTML is full of
    /// newlines/tabs around the real text).
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Watch page -> broadcaster name from og:title
    /// ("Steam Community :: {name} :: Broadcast") or <title>.
    /// Returns nil when the page carries no broadcast config
    /// (not a live broadcast page).
    static func broadcaster(fromWatchHTML html: String, steamID: String) -> String {
        guard let config = firstCapture(#"id="application_config"[^>]*data-broadcastsinfo="([^"]*)""#, in: html)?
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&"),
              let data = config.data(using: .utf8),
              let json = JSONValue.parse(data),
              json["steamid"].stringValue == steamID else {
            return "Steam broadcaster"
        }
        let title = firstCapture(#"<meta[^>]*property="og:title"[^>]*content="([^"]*)""#, in: html)
            ?? firstCapture(#"<title>([^<]*)</title>"#, in: html) ?? ""
        if let match = firstCapture(#"^Steam Community\s*::\s*(.+?)\s*::\s*Broadcast$"#, in: title, options: [.caseInsensitive]),
           !match.trimmingCharacters(in: .whitespaces).isEmpty {
            return match.trimmingCharacters(in: .whitespaces)
        }
        return "Steam broadcaster"
    }

    /// Pure parser for the getbroadcastmpd JSON. Returns nil when
    /// the broadcast is gone / the JSON is not a broadcast at all.
    static func broadcast(fromJSON json: JSONValue, steamID: String, broadcaster: String) -> BroadcastInfo? {
        let success = (json["success"].stringValue ?? "").lowercased()
        let isReplay = json["is_replay"].boolValue == true
        let isLive: Bool
        let restricted: Bool
        switch success {
        case "ready":
            isLive = !isReplay
            restricted = false
        case "missing_subscription":
            // Subscribers-only room: listed, not playable.
            isLive = true
            restricted = true
        case "unavailable", "offline", "not_live", "no_broadcast":
            isLive = false
            restricted = false
        case "user_restricted":
            isLive = false
            restricted = true
        default:
            isLive = false
            restricted = false
        }
        var master: String?
        if isLive || isReplay {
            if let raw = json["hls_url"].stringValue, !raw.isEmpty {
                master = validatedMasterURL(raw, steamID: steamID, cdnAuth: json["cdn_auth_url_parameters"].stringValue)
            }
            if master == nil && isLive && success == "ready" { return nil }
        }
        let title = json["title"].stringValue ?? ""
        return BroadcastInfo(
            title: title.isEmpty ? "Steam Broadcast" : title,
            viewerCount: json["num_viewers"].intValue,
            isLive: isLive,
            master: restricted ? nil : master,
            broadcastID: json["broadcastid"].stringValue ?? "",
            restricted: restricted
        )
    }

    /// hls_url validation: https, *.steamcontent.com, path
    /// /broadcast/{steamId}/{broadcastId}/hls_manifest/0/{host}/
    /// master.m3u8 with the host segment equal to the host, and a
    /// valid broadcast_origin. cdn_auth_url_parameters (if any) are
    /// appended verbatim.
    static func validatedMasterURL(_ raw: String, steamID: String, cdnAuth: String?) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              (host == "steamcontent.com" || host.hasSuffix(".steamcontent.com")),
              url.user == nil, url.fragment == nil, url.port == nil || url.port == 443 else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        // broadcast/{steamId}/{broadcastId}/hls_manifest/0/{host}/master.m3u8
        guard segments.count == 7,
              segments[0] == "broadcast",
              segments[1] == steamID,
              segments[3] == "hls_manifest",
              segments[4] == "0",
              segments[5].lowercased() == host,
              segments[6] == "master.m3u8",
              validOrigin(queryParam(url, "broadcast_origin")) else { return nil }
        var result = url.absoluteString
        if let auth = cdnAuth?.trimmingCharacters(in: .whitespacesAndNewlines), !auth.isEmpty {
            var rawAuth = auth
            while rawAuth.hasPrefix("&") || rawAuth.hasPrefix("?") { rawAuth.removeFirst() }
            guard !rawAuth.isEmpty, rawAuth.count <= 4096, !rawAuth.contains(" ") else { return nil }
            result += "&\(rawAuth)"
        }
        return result
    }

    static func validOrigin(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.count <= 255 else { return false }
        let host = value.lowercased()
        return host == "steamserver.net" || host.hasSuffix(".steamserver.net")
    }

    /// Master playlist validation: #EXTM3U, 1-16 variants, each
    /// child URL on the same host under /broadcast/{steamId}/
    /// hls_manifest/0/ with a valid broadcast_origin.
    static func isValidMaster(_ playlist: String, steamID: String, masterHost: String) -> Bool {
        guard playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return false }
        let lines = playlist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var variants = 0
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                variants += 1
                var next = index + 1
                while next < lines.count && lines[next].hasPrefix("#") { next += 1 }
                guard next < lines.count, isValidChild(lines[next], steamID: steamID, host: masterHost) else { return false }
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                guard let uri = firstCapture(#"URI="([^"]+)""#, in: line),
                      isValidChild(uri, steamID: steamID, host: masterHost) else { return false }
            }
        }
        return variants >= 1 && variants <= 16
    }

    static func isValidChild(_ raw: String, steamID: String, host: String) -> Bool {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.fragment == nil,
              url.host?.lowercased() == host.lowercased(),
              url.path.hasPrefix("/broadcast/\(steamID)/"),
              url.path.contains("/hls_manifest/0/"),
              validOrigin(queryParam(url, "broadcast_origin")) else { return false }
        return true
    }

    static func queryParam(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }

    static func playDataJSON(master: String?, broadcastID: String) -> String? {
        guard let master else { return nil }
        let escaped = master.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"master\":\"\(escaped)\",\"broadcastId\":\"\(broadcastID)\"}"
    }

    /// Bare 17-digit SteamID64 (7656119 + 10 digits) or a
    /// steamcommunity.com/broadcast/watch/{steamId} link.
    static func parseSteamID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^7656119[0-9]{10}$"#, options: .regularExpression) != nil {
            return value
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.lowercased() == "steamcommunity.com",
              url.fragment == nil else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 3, segments[0] == "broadcast", segments[1] == "watch",
              segments[2].range(of: #"^7656119[0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        return segments[2]
    }

    // MARK: - Regex helper
    static func firstCapture(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
