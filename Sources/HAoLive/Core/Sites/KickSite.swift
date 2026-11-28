// KickSite.swift
// HAo Live — real Kick adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28 (kick.com web app
// JS chunks at assets.kick.com, probed with curl; no login anywhere):
//   recommend / category
//     GET web.kick.com/api/v1/livestreams?limit=20&sort=featured_home
//         &language=en[&category_id=N][&after=<cursor>]
//         -> {data: {livestreams: [{id (uuid), title, viewer_count,
//             thumbnail: {src}, channel: {id, slug, profile_pic,
//             username}, category: {id, name, slug}, language,
//             is_mature, chatroom_id, start_time}],
//             pagination: {next_cursor}}}
//         (sort=viewers_high_to_low / recommended return 400
//         "Invalid request" anonymously; featured_home works.
//         The cursor is base64({"o": <offset>}) with the "="
//         padding stripped — verified: page 2 after=eyJvIjoyMH0
//         returns the next 5 rooms, next_cursor eyJvIjoyNX0.)
//   categories
//     GET kick.com/api/v1/categories/top
//         -> top-level array [{id, category_id, name, slug, tags,
//             is_mature, viewers, banner: {src}, category: {...}}]
//         (13 entries at probe time; /api/v1/subcategories is the
//         paged full tree, not needed for the top list.)
//   search
//     GET search.kick.com/api/v1/search/enriched?query=<q>
//         -> {data: {categories: [...], channels: [{id, slug,
//             username, profile_picture, follower_count, is_live,
//             is_verified}], livestreams: [<same item as the list>]}}
//   room detail
//     GET kick.com/api/v2/channels/{slug}
//         -> {id (channel id), slug, playback_url, livestream:
//             {id, slug, channel_id, session_title, is_live,
//              is_mature, viewer_count, thumbnail: {url},
//              categories: [{name, ...}]} | null, chatroom: {id},
//             user: {username, profile_pic}, is_banned}
//         (livestream is null while the channel is offline; the
//         channel-level playback_url is stale then, so playback
//         requires livestream.is_live == true.)
//   play URL: the channel playback_url is a signed HLS master
//         (.m3u8 with a token query) — used verbatim, one stream,
//         quality "原画", line "主线路". Kick serves a single
//         multivariant master playlist; there are no separate
//         quality tiers to list.
// Danmaku: public Pusher channel (see KickDanmaku.swift).
// Rooms flagged is_mature are skipped everywhere: Kick's web player
// gates mature streams behind login, and this app adds no
// login-gated feature.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class KickSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .kick
    private let http = HTTPClient.shared

    /// The web app's API host (NEXT_PUBLIC_APP_WEB_URL).
    private static let webBase = "https://web.kick.com"
    /// The Laravel host (NEXT_PUBLIC_BASE_LARAVEL_URL).
    private static let laravelBase = "https://kick.com"
    /// The search host (NEXT_PUBLIC_SEARCH_API_URL).
    private static let searchBase = "https://search.kick.com"

    private static let pageSize = 20

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.laravelBase)/api/v1/categories/top")
        return json.arrayValue.compactMap(Self.category(fromTopItem:))
    }

    /// Pure parser for one /api/v1/categories/top entry. Testable
    /// without the network. Mature categories are skipped (their
    /// rooms are login-gated on Kick).
    static func category(fromTopItem item: JSONValue) -> LiveCategory? {
        guard item["is_mature"].boolValue != true,
              let id = item["id"].intValue,
              let name = item["name"].stringValue, !name.isEmpty else { return nil }
        return LiveCategory(
            id: "kick-\(id)",
            platform: .kick,
            name: name,
            iconName: nil,
            iconURL: Self.imageURL(item["banner"]["src"].stringValue)
        )
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await livestreams(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        return try await livestreams(page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await livestreams(categoryID: Self.categoryID(of: category), page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        return try await livestreams(categoryID: Self.categoryID(of: category), page: page)
    }

    /// Numeric Kick category id carried in the LiveCategory id
    /// ("kick-<id>").
    static func categoryID(of category: LiveCategory) -> Int? {
        Int(category.id.dropFirst("kick-".count))
    }

    /// One page of the web livestreams list, optionally filtered to
    /// a category. Paging is offset-based: the `after` cursor is
    /// base64({"o": offset}) with padding stripped.
    private func livestreams(categoryID: Int? = nil, page: Int = 1) async throws -> [LiveRoom] {
        var url = "\(Self.webBase)/api/v1/livestreams?limit=\(Self.pageSize)&sort=featured_home&language=en"
        if let categoryID {
            url += "&category_id=\(categoryID)"
        }
        if page > 1 {
            let cursor = Self.cursor(offset: (page - 1) * Self.pageSize)
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            url += "&after=\(encoded)"
        }
        let json = try await http.getJSON(url)
        return json["data"]["livestreams"].arrayValue.compactMap(Self.room(fromLivestream:))
    }

    /// The list cursor for an offset: base64({"o": offset}) with
    /// the "=" padding stripped, matching what the server emits
    /// ({"o":20} -> "eyJvIjoyMH0"). Testable without the network.
    static func cursor(offset: Int) -> String {
        let raw = "{\"o\":\(offset)}"
        return Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        let json = try await enrichedSearch(keyword: keyword)
        return json["data"]["livestreams"].arrayValue.compactMap(Self.room(fromLivestream:))
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        let json = try await enrichedSearch(keyword: keyword)
        let live = json["data"]["livestreams"].arrayValue.compactMap(Self.room(fromLivestream:))
        var rooms: [LiveRoom] = []
        for channel in json["data"]["channels"].arrayValue {
            guard channel["is_live"].boolValue == true,
                  let slug = channel["slug"].stringValue, !slug.isEmpty else { continue }
            // Prefer the full livestream item (title / cover /
            // viewers) when the search returned one for this slug.
            if let match = live.first(where: { $0.roomID == slug }) {
                rooms.append(match)
                continue
            }
            rooms.append(LiveRoom(
                id: "kick-\(slug)",
                platform: .kick,
                roomID: slug,
                title: channel["username"].stringValue ?? "",
                anchorName: channel["username"].stringValue ?? "",
                anchorAvatarURL: Self.imageURL(channel["profile_picture"].stringValue),
                coverURL: nil,
                categoryName: nil,
                viewerCount: 0,
                isLive: true
            ))
        }
        return rooms
    }

    /// The enriched search endpoint (categories + channels +
    /// livestreams in one response).
    private func enrichedSearch(keyword: String) async throws -> JSONValue {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        return try await http.getJSON("\(Self.searchBase)/api/v1/search/enriched?query=\(encoded)")
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let slug = Self.slug(from: roomID)
        let channel = try await Self.channel(slug: slug)
        guard channel["is_banned"].boolValue != true else {
            throw LiveSiteError.roomNotFound(slug)
        }
        return Self.room(fromChannel: channel, fallbackSlug: slug)
    }

    /// GET kick.com/api/v2/channels/{slug}. A 404 means the channel
    /// does not exist.
    static func channel(slug: String) async throws -> JSONValue {
        do {
            return try await HTTPClient.shared.getJSON("\(Self.laravelBase)/api/v2/channels/\(slug)")
        } catch LiveSiteError.httpStatus(let code) where code == 404 {
            throw LiveSiteError.roomNotFound(slug)
        }
    }

    /// Pure parser for the channel object. Testable without the
    /// network. An offline channel still yields a room (isLive
    /// false) — only a banned/missing channel is an error.
    static func room(fromChannel channel: JSONValue, fallbackSlug: String) -> LiveRoom {
        let slug = channel["slug"].stringValue ?? fallbackSlug
        let livestream = channel["livestream"]
        let isLive = livestream["is_live"].boolValue == true
        let categoryName = livestream["categories"][0]["name"].stringValue
            ?? livestream["category"]["name"].stringValue
        return LiveRoom(
            id: "kick-\(slug)",
            platform: .kick,
            roomID: slug,
            title: livestream["session_title"].stringValue ?? "",
            anchorName: channel["user"]["username"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(channel["user"]["profile_pic"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(
                livestream["thumbnail"]["url"].stringValue,
                livestream["thumbnail"]["src"].stringValue
            )),
            categoryName: categoryName,
            viewerCount: livestream["viewer_count"].intValue ?? 0,
            isLive: isLive
        )
    }

    // MARK: - Play URLs

    /// The channel playback_url is a signed HLS master playlist —
    /// used verbatim (query token included), one stream. Offline
    /// channels carry a stale playback_url, so a room whose
    /// livestream is not live yields no stream; mature rooms yield
    /// none either (login-gated on Kick).
    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let slug = Self.slug(from: room.roomID)
        let channel = try await Self.channel(slug: slug)
        let livestream = channel["livestream"]
        guard !livestream.isNull,
              livestream["is_live"].boolValue == true,
              livestream["is_mature"].boolValue != true else { return [] }
        guard let urlString = HaoText.firstNonEmpty(
                  channel["playback_url"].stringValue,
                  livestream["playback_url"].stringValue),
              !urlString.isEmpty,
              let url = URL(string: urlString) else { return [] }
        return [PlayStream(
            url: url,
            quality: "原画",
            line: "主线路",
            headers: PlaybackHeaders.headers(platform: .kick, roomID: slug)
        )]
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return KickDanmaku.stream(roomID: Self.slug(from: roomID))
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Mapping helpers

    /// Pure parser for a livestreams-list item (recommend /
    /// category / search-enriched livestreams). Testable without the
    /// network. Mature rooms are skipped (login-gated on Kick).
    static func room(fromLivestream item: JSONValue) -> LiveRoom? {
        guard item["is_mature"].boolValue != true,
              let slug = item["channel"]["slug"].stringValue, !slug.isEmpty else { return nil }
        return LiveRoom(
            id: "kick-\(slug)",
            platform: .kick,
            roomID: slug,
            title: item["title"].stringValue ?? "",
            anchorName: item["channel"]["username"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(HaoText.firstNonEmpty(
                item["channel"]["profile_pic"].stringValue,
                item["channel"]["profile_picture"].stringValue
            )),
            coverURL: Self.imageURL(item["thumbnail"]["src"].stringValue),
            categoryName: item["category"]["name"].stringValue,
            viewerCount: item["viewer_count"].intValue ?? 0,
            isLive: true
        )
    }

    /// Room ids in this adapter are channel slugs; tolerate a
    /// "kick-" prefix if one ever arrives.
    static func slug(from roomID: String) -> String {
        roomID.hasPrefix("kick-") ? String(roomID.dropFirst("kick-".count)) : roomID
    }
}
