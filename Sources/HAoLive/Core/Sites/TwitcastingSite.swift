// TwitcastingSite.swift
// HAo Live — real TwitCasting adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   categories  GET https://twitcasting.tv/ (HTML)
//               -> a.tw-top-tab-item[data-channel] (key + label)
//   list        GET https://frontendapi.twitcasting.tv/top/category
//               ?id={category}&count=60
//               -> {movies: [{id, title, telop, live_url "/{channel}/movie/{id}",
//                  user_id, user_name, thumbnail_url, user_icon_url,
//                  current_viewer_count, is_live, is_locked, is_group,
//                  is_deleted}]} — bounded 60-item window, paged locally.
//   search      GET https://search.twitcasting.tv/search/text/{keyword}?hl=en
//               (HTML) -> #tw-search-result-live .tw-search-result-row;
//               only rows with a data-status="live" badge AND
//               data-can-play="true" are playable (private /
//               unplayable rows are skipped, never listed).
//   detail      GET https://twitcasting.tv/{channel} (HTML; the text
//               "Enter the secret word" means a password room —
//               skipped, reported not-live) then
//               GET https://twitcasting.tv/streamserver.php
//               ?target={channel}&mode=client&player=pc_web
//               -> {movie: {id, live}, tc-hls: {streams: {high, medium,
//                  low}}} — movie.live == false means every URL in
//               the response is stale data for another movie and
//               must be ignored (Pure Live's rule, ported).
// Danmaku: TwitcastingDanmaku (POST eventpubsuburl.php -> wss URL,
// JSON comment frames). No login anywhere.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TwitcastingSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .twitcasting
    private let http = HTTPClient.shared

    private static let webBase = "https://twitcasting.tv"
    private static let directoryBase = "https://frontendapi.twitcasting.tv"
    private static let searchBase = "https://search.twitcasting.tv"
    private static let directoryWindow = 60
    private static let pageSize = 30
    private static let searchWindow = 50

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        let data = try await http.get("\(Self.webBase)/")
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return Self.categories(fromHomeHTML: html)
    }

    /// Pure parser for the home page's tab anchors. Testable without
    /// the network. The label sits after an inline SVG, so the inner
    /// HTML is tag-stripped instead of read as direct text.
    static func categories(fromHomeHTML html: String) -> [LiveCategory] {
        var seen = Set<String>()
        var out: [LiveCategory] = []
        for (tag, tagRange) in Self.anchorTagsWithRanges(in: html) {
            guard tag.contains("tw-top-tab-item"),
                  let key = Self.firstGroup(#"data-channel="([^"]+)""#, in: tag),
                  !key.isEmpty, seen.insert(key).inserted else { continue }
            guard let close = html.range(of: "</a>", range: tagRange.upperBound..<html.endIndex) else { continue }
            let inner = String(html[tagRange.upperBound..<close.lowerBound])
            let label = HaoText.stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            out.append(LiveCategory(id: "twitcasting-\(key)", platform: .twitcasting, name: label, iconName: nil))
        }
        return out
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await directory(category: "", page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await directory(category: "", page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        guard let key = Self.categoryKey(from: category.id) else { return [] }
        return try await directory(category: key, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard let key = Self.categoryKey(from: category.id) else { return [] }
        return try await directory(category: key, page: page)
    }

    static func categoryKey(from categoryID: String) -> String? {
        guard categoryID.hasPrefix("twitcasting-") else { return nil }
        let key = String(categoryID.dropFirst("twitcasting-".count))
        return key.isEmpty ? nil : key
    }

    private func directory(category: String, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let offset = (page - 1) * Self.pageSize
        guard offset < Self.directoryWindow else { return [] }
        let encoded = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        let json = try await http.getJSON("\(Self.directoryBase)/top/category?id=\(encoded)&count=\(Self.directoryWindow)")
        let movies = json["movies"].arrayValue
        return movies
            .dropFirst(offset)
            .prefix(Self.pageSize)
            .compactMap(Self.room(fromMovie:))
    }

    /// Pure parser for one frontendapi movie row. Returns nil for
    /// anything that is not a currently-live public broadcast
    /// (offline / locked / group / deleted).
    static func room(fromMovie item: JSONValue) -> LiveRoom? {
        guard item["is_live"].boolValue == true,
              item["is_locked"].boolValue == false,
              item["is_group"].boolValue == false,
              item["is_deleted"].boolValue == false else { return nil }
        let liveURL = item["live_url"].stringValue ?? ""
        let segments = liveURL.split(separator: "/").map(String.init)
        guard segments.count == 3, segments[1] == "movie" else { return nil }
        let channel = segments[0].lowercased()
        guard !channel.isEmpty else { return nil }
        let movieID = item["id"].stringValue ?? segments[2]
        let title = HaoText.firstNonEmpty(item["telop"].stringValue, item["title"].stringValue) ?? ""
        return LiveRoom(
            id: "twitcasting-\(channel)",
            platform: .twitcasting,
            roomID: channel,
            title: title,
            anchorName: item["user_name"].stringValue ?? channel,
            anchorAvatarURL: Self.imageURL(item["user_icon_url"].stringValue),
            coverURL: Self.imageURL(item["thumbnail_url"].stringValue),
            categoryName: nil,
            viewerCount: item["current_viewer_count"].intValue ?? 0,
            isLive: true,
            playDataJSON: "{\"movieId\":\(movieID)}"
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

    private func search(keyword: String, page: Int) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, page >= 1 else { return [] }
        // A channel URL resolves directly to that channel's detail.
        if let channel = Self.channelFromURLString(query), page == 1 {
            if let room = try? await roomDetail(roomID: channel), room.isLive {
                return [room]
            }
            return []
        }
        let offset = (page - 1) * 20
        guard offset < Self.searchWindow else { return [] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        let data = try await http.get("\(Self.searchBase)/search/text/\(encoded)?hl=en")
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return Array(Self.rooms(fromSearchHTML: html).dropFirst(offset).prefix(20))
    }

    /// A twitcasting.tv channel URL (single path segment) -> channel,
    /// nil for anything else (movie/archive links included: they name
    /// an old broadcast, not the channel's current live session).
    static func channelFromURLString(_ value: String) -> String? {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "twitcasting.tv" || host == "www.twitcasting.tv" else { return nil }
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count == 1 else { return nil }
        let channel = segments[0].lowercased()
        guard !channel.isEmpty,
              channel.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil,
              !["search", "help", "login", "logout", "settings", "signup", "register", "terms", "privacy", "about", "index", "show", "categories"].contains(channel) else { return nil }
        return channel
    }

    /// Pure parser for the search page's live section. Only rows with
    /// a live badge and data-can-play="true" survive; shop / premier /
    /// archive rows in other sections are never touched (the parse is
    /// scoped to the #tw-search-result-live div). Rows are split on
    /// their own <div> so a row's window can never bleed into the
    /// next row. The live title span is often empty — the row's
    /// user description is the fallback title.
    static func rooms(fromSearchHTML html: String) -> [LiveRoom] {
        guard let idRange = html.range(of: "id=\"tw-search-result-live\"") else { return [] }
        var section = String(html[idRange.lowerBound...])
        // The live section ends where the next search section begins.
        let cutFrom = section.index(section.startIndex, offsetBy: min(30, section.count))
        if let next = section.range(of: "id=\"tw-search-result-", range: cutFrom..<section.endIndex) {
            section = String(section[..<next.lowerBound])
        }
        let rowMarker = "<div class=\"tw-search-result-row\">"
        let chunks = section.components(separatedBy: rowMarker)
        guard chunks.count > 1 else { return [] }
        var seen = Set<String>()
        var out: [LiveRoom] = []
        for window in chunks.dropFirst() {
            guard let href = Self.firstGroup(#"<a[^>]*class="[^"]*tw-movie-thumbnail2[^"]*"[^>]*href="([^"]+)""#, in: window)
                    ?? Self.firstGroup(#"<a[^>]*href="([^"]+)"[^>]*class="[^"]*tw-movie-thumbnail2[^"]*""#, in: window) else { continue }
            let segments = href.split(separator: "/").map(String.init)
            guard segments.count == 3, segments[1] == "movie",
                  let movieID = Int(segments[2]), movieID > 0 else { continue }
            let channel = segments[0].lowercased()
            guard !channel.isEmpty, seen.insert(channel).inserted else { continue }
            guard window.contains("data-status=\"live\""),
                  window.contains("data-can-play=\"true\"") else { continue }
            let title = HaoText.firstNonEmpty(
                Self.firstGroup(#"tw-movie-thumbnail-title[^>]*>([^<]*)"#, in: window).map { HaoText.stripTags($0).trimmingCharacters(in: .whitespacesAndNewlines) },
                Self.firstGroup(#"tw-search-result-row-user-desc[^>]*>([^<]*)"#, in: window).map { HaoText.stripTags($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ) ?? ""
            let cover = Self.firstGroup(#"<img[^>]*class="[^"]*tw-movie-thumbnail2-image[^"]*"[^>]*src="([^"]+)""#, in: window)
                ?? Self.firstGroup(#"tw-movie-thumbnail2-image[^>]*src="([^"]+)""#, in: window)
            let avatar = Self.firstGroup(#"userimage32[\s\S]{0,600}?<img[^>]*src="([^"]+)""#, in: window)
            let nick = Self.firstGroup(#"class="username"[^>]*>([^<]*)"#, in: window).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? channel
            out.append(LiveRoom(
                id: "twitcasting-\(channel)",
                platform: .twitcasting,
                roomID: channel,
                title: title,
                anchorName: nick,
                anchorAvatarURL: Self.imageURL(avatar),
                coverURL: Self.imageURL(cover),
                categoryName: nil,
                viewerCount: 0,
                isLive: true,
                playDataJSON: "{\"movieId\":\(movieID)}"
            ))
        }
        return out
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let channel = roomID.lowercased()
        let data = try await http.get("\(Self.webBase)/\(channel)")
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        // Password room: never listed as playable.
        if html.contains("Enter the secret word") {
            return LiveRoom(
                id: "twitcasting-\(channel)",
                platform: .twitcasting,
                roomID: channel,
                title: "",
                anchorName: channel,
                anchorAvatarURL: nil,
                coverURL: nil,
                categoryName: nil,
                viewerCount: 0,
                isLive: false
            )
        }
        let stream = try await streamServer(channel: channel)
        let title = HaoText.firstNonEmpty(
            Self.firstGroup(#"tw-player-page-title-description[^>]*>([^<]*)"#, in: html).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            Self.firstGroup(#"<meta[^>]*name="twitter:title"[^>]*content="([^"]*)""#, in: html)
        ) ?? ""
        let nick = Self.firstGroup(#"tw-user-nav2-name[^>]*>([^<]*)"#, in: html).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? channel
        let avatar = Self.firstGroup(#"tw-user-nav2-icon[\s\S]{0,400}?<img[^>]*src="([^"]+)""#, in: html)
        let cover = Self.firstGroup(#"<meta[^>]*property="og:image"[^>]*content="([^"]*)""#, in: html)
        return LiveRoom(
            id: "twitcasting-\(channel)",
            platform: .twitcasting,
            roomID: channel,
            title: title,
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(avatar),
            coverURL: Self.imageURL(cover),
            categoryName: nil,
            viewerCount: 0,
            isLive: stream.live,
            playDataJSON: stream.live ? "{\"movieId\":\(stream.movieID)}" : nil
        )
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let channel = room.roomID.lowercased()
        let stream = try await streamServer(channel: channel)
        guard stream.live else { return [] }
        let headers = PlaybackHeaders.headers(platform: .twitcasting, roomID: channel)
        var out: [PlayStream] = []
        for (key, quality) in [("high", "高画质"), ("medium", "中画质"), ("low", "低画质")] {
            guard let urlString = stream.streams[key], !urlString.isEmpty,
                  let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  (host == "twitcasting.tv" || host.hasSuffix(".twitcasting.tv")) else { continue }
            out.append(PlayStream(url: url, quality: quality, line: "主线路", headers: headers))
        }
        return out
    }

    /// The streamserver.php response: live flag, movie id, and the
    /// tc-hls stream URLs (empty when offline — the caller must check
    /// `live` first and ignore every URL when it is false).
    struct StreamServerResult {
        var live: Bool
        var movieID: Int
        var streams: [String: String]
    }

    private func streamServer(channel: String) async throws -> StreamServerResult {
        let json = try await http.getJSON("\(Self.webBase)/streamserver.php?target=\(channel)&mode=client&player=pc_web")
        return Self.streamServerResult(from: json)
    }

    static func streamServerResult(from json: JSONValue) -> StreamServerResult {
        let movie = json["movie"]
        let live = movie["live"].boolValue == true
        let movieID = movie["id"].intValue ?? 0
        var streams: [String: String] = [:]
        for key in ["high", "medium", "low"] {
            if let url = json["tc-hls"]["streams"][key].stringValue, !url.isEmpty {
                streams[key] = url
            }
        }
        return StreamServerResult(live: live, movieID: movieID, streams: streams)
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return TwitcastingDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Tiny HTML helpers (no HTML parser on iOS/Linux)

    /// All `<a ...>` opening tags with their ranges, in order.
    static func anchorTagsWithRanges(in html: String) -> [(String, Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: "<a\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let r = Range(match.range, in: html) else { return nil }
            return (String(html[r]), r)
        }
    }

    /// First capture group of the first match, nil when no match.
    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
