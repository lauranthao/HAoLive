// ShowroomSite.swift
// HAo Live — real SHOWROOM adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   catalog     GET https://www.showroom-live.com/api/live/onlives
//               -> {onlives: [{genre_id, genre_name,
//                  lives: [{room_id, room_url_key, main_name, telop,
//                  image_square, genre_id, genre_name, follower_num,
//                  view_num, premium_room_type, streaming_url_list:
//                  [{id, type, label, quality, url, is_default}]}]}]}
//               — a COMPLETE snapshot, not a paged endpoint: genres
//               are the categories, every list is paged locally
//               (30/page). Rows with cell_type 7 and no room_id are
//               "nobody live" message cells, not rooms. Rows with
//               premium_room_type != 0 are paid rooms and are skipped.
//               view_num is session traffic, not concurrent viewers.
//   search      No server search: the snapshot is filtered locally
//               (room id, room_url_key, name, telop, genre name).
//   detail      GET /api/room/status?room_url_key= (url_key <->
//               room_id) -> GET /api/room/profile?room_id=
//               (main_name, image_square, genre, follower_num,
//               view_num, is_onlive, premium_room_type) +
//               GET /api/live/live_info?room_id= (live_status == 2
//               is live; also bcsvr_host / bcsvr_key for danmaku).
//   play        GET /api/live/streaming_url?room_id=&abr_available=1
//               -> {streaming_url_list: [{id, type, label, quality,
//               url, is_default}]} — only type hls and hls_all are
//               taken (webrtc entries are skipped: the player has no
//               WebRTC input). Labels: hls_all = 自动, quality >=
//               1000 = 原画, >= 200 = 中画质, else 低画质.
// Danmaku: ShowroomDanmaku (wss://{bcsvr_host}/, SUB + key, MSG
// frames). No login anywhere.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ShowroomSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .showroom
    private let http = HTTPClient.shared

    private static let webBase = "https://www.showroom-live.com"
    private static let pageSize = 30

    /// The onlives snapshot, cached 30s (Pure Live's window) so
    /// categories / recommend / search do not re-download ~370 KB
    /// on every call. The snapshot itself is immutable once built.
    private var cachedCatalog: Catalog?
    private var cachedAt: Date?

    struct Genre {
        var id: Int
        var name: String
        var lives: [Live]
    }

    struct Stream {
        var id: Int
        var type: String
        var label: String
        var quality: Int
        var url: String
        var isDefault: Bool
    }

    struct Live {
        var roomID: Int
        var roomURLKey: String
        var name: String
        var cover: String
        var genreID: Int
        var genreName: String
        var followers: Int?
        var totalViewers: Int?
        var telop: String
        var streams: [Stream]
        var premiumRoomType: Int
    }

    struct Catalog {
        var genres: [Genre]
        var uniqueLives: [Live] {
            var seen = Set<Int>()
            var out: [Live] = []
            for genre in genres {
                for live in genre.lives where seen.insert(live.roomID).inserted {
                    out.append(live)
                }
            }
            return out
        }
    }

    // MARK: - Catalog

    private func catalog() async throws -> Catalog {
        if let cached = cachedCatalog, let at = cachedAt,
           Date().timeIntervalSince(at) < 30 {
            return cached
        }
        let json = try await http.getJSON("\(Self.webBase)/api/live/onlives")
        let catalog = Self.catalog(fromJSON: json)
        cachedCatalog = catalog
        cachedAt = Date()
        return catalog
    }

    /// Pure parser for the onlives snapshot. Paid rooms
    /// (premium_room_type != 0) and message cells (no room_id) are
    /// dropped here so no list ever shows them.
    static func catalog(fromJSON json: JSONValue) -> Catalog {
        var genres: [Genre] = []
        var seenGenres = Set<Int>()
        for group in json["onlives"].arrayValue {
            guard let genreID = group["genre_id"].intValue,
                  seenGenres.insert(genreID).inserted else { continue }
            let name = group["genre_name"].stringValue ?? ""
            var lives: [Live] = []
            for row in group["lives"].arrayValue {
                if let live = Self.live(fromRow: row) {
                    lives.append(live)
                }
            }
            genres.append(Genre(id: genreID, name: name, lives: lives))
        }
        return Catalog(genres: genres)
    }

    static func live(fromRow row: JSONValue) -> Live? {
        guard let roomID = row["room_id"].intValue, roomID > 0 else { return nil }
        let premium = row["premium_room_type"].intValue ?? 0
        guard premium == 0 else { return nil }
        return Live(
            roomID: roomID,
            roomURLKey: row["room_url_key"].stringValue ?? "",
            name: row["main_name"].stringValue ?? "",
            cover: row["image_square"].stringValue ?? row["image"].stringValue ?? "",
            genreID: row["genre_id"].intValue ?? 0,
            genreName: row["genre_name"].stringValue ?? "",
            followers: row["follower_num"].intValue,
            totalViewers: row["view_num"].intValue,
            telop: row["telop"].stringValue ?? "",
            streams: Self.streams(fromList: row["streaming_url_list"]),
            premiumRoomType: premium
        )
    }

    /// Only hls / hls_all entries, deduplicated by URL.
    static func streams(fromList value: JSONValue) -> [Stream] {
        var seen = Set<String>()
        var out: [Stream] = []
        for row in value.arrayValue {
            let type = row["type"].stringValue ?? ""
            guard type == "hls" || type == "hls_all",
                  let url = mediaURL(row["url"].stringValue),
                  seen.insert(url).inserted else { continue }
            out.append(Stream(
                id: row["id"].intValue ?? 0,
                type: type,
                label: row["label"].stringValue ?? "",
                quality: row["quality"].intValue ?? 0,
                url: url,
                isDefault: row["is_default"].boolValue == true
            ))
        }
        return out
    }

    /// Stream URLs must be https on a SHOWROOM host. Anything else
    /// (webrtc://, other hosts) is not a playable HLS URL.
    static func mediaURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "showroom-live.com" || host.hasSuffix(".showroom-live.com")
                || host == "showroom-txlive.com" || host.hasSuffix(".showroom-txlive.com") else { return nil }
        return value
    }

    static func qualityLabel(for stream: Stream) -> String {
        if stream.type == "hls_all" { return "自动" }
        if stream.quality >= 1000 { return "原画" }
        if stream.quality >= 200 { return "中画质" }
        return "低画质"
    }

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        let catalog = try await catalog()
        return catalog.genres.map { genre in
            LiveCategory(id: "showroom-genre:\(genre.id)", platform: .showroom, name: genre.name, iconName: nil)
        }
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        let catalog = try await catalog()
        let lives = Self.popularLives(in: catalog)
        return pageSlice(lives, page: page).map(Self.room(fromLive:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let catalog = try await catalog()
        guard let genreID = Self.genreID(from: category.id),
              let genre = catalog.genres.first(where: { $0.id == genreID }) else { return [] }
        return pageSlice(genre.lives, page: page).map(Self.room(fromLive:))
    }

    /// Genre 0 is the "popular" group; without it, the deduped
    /// snapshot is the recommendation list.
    static func popularLives(in catalog: Catalog) -> [Live] {
        if let popular = catalog.genres.first(where: { $0.id == 0 }) {
            return popular.lives
        }
        return catalog.uniqueLives
    }

    static func genreID(from categoryID: String) -> Int? {
        guard categoryID.hasPrefix("showroom-genre:") else { return nil }
        return Int(categoryID.dropFirst("showroom-genre:".count))
    }

    private func pageSlice(_ lives: [Live], page: Int) -> [Live] {
        guard page >= 1 else { return [] }
        let start = (page - 1) * Self.pageSize
        guard start < lives.count else { return [] }
        return Array(lives[start..<min(start + Self.pageSize, lives.count)])
    }

    static func room(fromLive live: Live) -> LiveRoom {
        LiveRoom(
            id: "showroom-\(live.roomID)",
            platform: .showroom,
            roomID: "\(live.roomID)",
            title: live.telop.isEmpty ? live.name : live.telop,
            anchorName: live.name,
            anchorAvatarURL: Self.imageURL(live.cover.isEmpty ? nil : live.cover),
            coverURL: Self.imageURL(live.cover.isEmpty ? nil : live.cover),
            categoryName: live.genreName.isEmpty ? nil : live.genreName,
            viewerCount: live.totalViewers ?? 0,
            isLive: true,
            playDataJSON: streamsJSON(live.streams)
        )
    }

    /// The snapshot's own stream list, carried on the room so
    /// playURLs does not have to re-fetch streaming_url (the URLs
    /// are per-broadcast and go stale when the broadcast ends, so
    /// playURLs falls back to a fresh fetch when they are absent).
    static func streamsJSON(_ streams: [Stream]) -> String? {
        guard !streams.isEmpty else { return nil }
        let items = streams.map { stream in
            "{\"type\":\"\(stream.type)\",\"quality\":\(stream.quality),\"url\":\"\(stream.url)\"}"
        }
        return "{\"streams\":[\(items.joined(separator: ","))]}"
    }

    // MARK: - Search (local filter over the snapshot)

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
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let catalog = try await catalog()
        let matches = catalog.uniqueLives.filter { live in
            "\(live.roomID)" == query
                || live.roomURLKey.lowercased() == query
                || live.name.lowercased().contains(query)
                || live.telop.lowercased().contains(query)
                || live.genreName.lowercased().contains(query)
        }
        return pageSlice(matches, page: page).map(Self.room(fromLive:))
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let id = try await resolveRoomID(roomID)
        let profileJSON = try await http.getJSON("\(Self.webBase)/api/room/profile?room_id=\(id)")
        guard profileJSON["room_id"].intValue == id else { throw LiveSiteError.roomNotFound(roomID) }
        let liveInfo = try await http.getJSON("\(Self.webBase)/api/live/live_info?room_id=\(id)")
        let isLive = (liveInfo["live_status"].intValue ?? 0) == 2
        let premium = profileJSON["premium_room_type"].intValue ?? 0
        let name = profileJSON["main_name"].stringValue ?? profileJSON["room_name"].stringValue ?? ""
        let cover = profileJSON["image_square"].stringValue ?? ""
        var playData: String? = nil
        var streams: [Stream] = []
        if isLive && premium == 0 {
            streams = try await fetchStreams(roomID: id)
            let chatHost = Self.commentHost(liveInfo["bcsvr_host"].stringValue)
            let chatKey = Self.commentKey(liveInfo["bcsvr_key"].stringValue)
            playData = Self.chatJSON(streams: streams, host: chatHost, key: chatKey)
        }
        return LiveRoom(
            id: "showroom-\(id)",
            platform: .showroom,
            roomID: "\(id)",
            title: name,
            anchorName: name,
            anchorAvatarURL: Self.imageURL(cover.isEmpty ? nil : cover),
            coverURL: Self.imageURL(cover.isEmpty ? nil : cover),
            categoryName: profileJSON["genre_name"].stringValue,
            viewerCount: profileJSON["view_num"].intValue ?? 0,
            isLive: isLive && premium == 0,
            playDataJSON: playData
        )
    }

    /// Numeric room id, or a room_url_key resolved via /api/room/status.
    private func resolveRoomID(_ reference: String) async throws -> Int {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numeric = Int(trimmed), numeric > 0 { return numeric }
        guard trimmed.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            throw LiveSiteError.roomNotFound(reference)
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let json = try await http.getJSON("\(Self.webBase)/api/room/status?room_url_key=\(encoded)")
        guard let id = json["room_id"].intValue, id > 0 else { throw LiveSiteError.roomNotFound(reference) }
        return id
    }

    private func fetchStreams(roomID: Int) async throws -> [Stream] {
        let json = try await http.getJSON("\(Self.webBase)/api/live/streaming_url?room_id=\(roomID)&abr_available=1")
        return Self.streams(fromList: json["streaming_url_list"])
    }

    /// bcsvr_host must be a bare showroom-live.com host; the key is
    /// an opaque token (no whitespace/control chars, <= 256 chars).
    static func commentHost(_ value: String?) -> String {
        guard let value else { return "" }
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), !host.contains(" "),
              host == "showroom-live.com" || host.hasSuffix(".showroom-live.com") else { return "" }
        return host
    }

    static func commentKey(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 256,
              !value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else { return "" }
        return value
    }

    static func chatJSON(streams: [Stream], host: String, key: String) -> String? {
        guard !streams.isEmpty else { return nil }
        let items = streams.map { stream in
            "{\"type\":\"\(stream.type)\",\"quality\":\(stream.quality),\"url\":\"\(stream.url)\"}"
        }
        // The chat host/key can contain ':' but never '"' or '\\' in
        // practice; they are validated above and emitted raw.
        return "{\"streams\":[\(items.joined(separator: ","))],\"chatHost\":\"\(host)\",\"chatKey\":\"\(key)\"}"
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        var streams: [Stream] = []
        if let data = room.playDataJSON.flatMap({ $0.data(using: .utf8) }),
           let json = JSONValue.parse(data) {
            streams = Self.streams(fromList: json["streams"])
        }
        if streams.isEmpty {
            let detail = try await roomDetail(roomID: room.roomID)
            guard detail.isLive else { return [] }
            if let data = detail.playDataJSON.flatMap({ $0.data(using: .utf8) }),
               let json = JSONValue.parse(data) {
                streams = Self.streams(fromList: json["streams"])
            }
        }
        guard !streams.isEmpty else { return [] }
        let headers = PlaybackHeaders.headers(platform: .showroom, roomID: room.roomID)
        // Best first: hls_all (auto) first, then quality descending.
        let sorted = streams.sorted { a, b in
            if (a.type == "hls_all") != (b.type == "hls_all") { return a.type == "hls_all" }
            return a.quality > b.quality
        }
        return sorted.compactMap { stream in
            guard let url = URL(string: stream.url) else { return nil }
            return PlayStream(url: url, quality: Self.qualityLabel(for: stream), line: "主线路", headers: headers)
        }
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return ShowroomDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }
}
