// BigoSite.swift
// HAo Live — real Bigo Live adapter (anonymous, no login).
// Pure Live's bigo_site.dart / bigo_api.dart, re-implemented from
// scratch for HAo Live. Endpoints verified live from this VM
// 2026-11-28 (HTTP 200):
//   list    GET ta.bigo.tv/official_website/OInterfaceWeb/vedioList/
//           72?tabType=00&fetchNum=10&lang=en&countryCode=US
//           -> {code 0, data{resCode "0", data[] {bigo_id,
//           owner, sid, room_topic, nick_name, cover_m,
//           user_count, is_locked, room_flag}}} — the server
//           returned 20 rows despite fetchNum=10. One "public"
//           category only (id 72); local paging, 20 per page;
//           the snapshot is cached 30 s.
//   detail  POST …/studio/getInternalStudioInfo
//           ?siteId=&verify=&token=<web token> — the token comes
//           from sec.bigo.sg/v1/webjs (see BigoRecipe.swift).
//           -> {code 0, data{uid, clientBigoId, nick_name,
//           roomTopic, gameTitle, avatar, snapshot, roomId,
//           roomStatus, alive, needLogin, passRoom, isPaidShow,
//           hls_src}}. access: needLogin = login wall (cannot
//           play, never listed as playable); passRoom / isPaidShow
//           = password / paid (cannot play). Verified live: with
//           an invalid token the call still answers with metadata
//           (needLogin false, alive 1) but hls_src EMPTY — see
//           BigoRecipe.swift for the token status.
//   search  No server search. Exact bigo.tv link / site id ->
//           studioRoom; otherwise the snapshot is filtered
//           locally by nickname / title.
//   play    No direct URL in the recipe sense: the studio room's
//           hls_src IS the HLS address (one quality, "live").
//           Pure Live feeds it to an ffmpeg relay that un-masks
//           protected segments (BigoHlsProtection); HAoLive's
//           mpv has no such step yet — see BigoRecipe.swift.
//           playURLs returns the hls_src verbatim with Bigo's
//           web headers, and [] when the room has none.
//   danmaku BigoDanmaku.swift (chat WS, guest account from
//           getWebSocketLink). NOT verified live from this VM —
//           the WS handshake needs a live room's guest account;
//           the flow is implemented per the reference.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BigoSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .bigo
    private let http = HTTPClient.shared

    private static let directoryURL = "https://ta.bigo.tv/official_website/OInterfaceWeb/vedioList/72?tabType=00&fetchNum=10&lang=en&countryCode=US"
    private static let pageSize = 20

    /// 30-second snapshot cache (Pure Live's BigoSite._directory).
    private var cachedDirectory: [BigoDirectoryCard]?
    private var cachedDirectoryAt: Date?

    // MARK: - Categories (one public category)

    func categories() async throws -> [LiveCategory] {
        [LiveCategory(id: "bigo-72", platform: .bigo, name: "公开", iconName: nil, iconURL: nil)]
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        Self.page(try await directory(), page: page, size: Self.pageSize).map(Self.room(fromCard:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard category.id == "bigo-72" || category.platform == .bigo else { return [] }
        return try await recommendRooms(page: page)
    }

    /// The recommendation snapshot, cached 30 s. Locked
    /// (password) rooms are dropped here — they are never listed
    /// as playable rooms.
    private func directory() async throws -> [BigoDirectoryCard] {
        if let cached = cachedDirectory, let at = cachedDirectoryAt,
           Date().timeIntervalSince(at) < 30 {
            return cached
        }
        let json = try await http.getJSON(Self.directoryURL, headers: BigoRecipe.headers)
        let cards = Self.cards(fromDirectory: json)
        cachedDirectory = cards
        cachedDirectoryAt = Date()
        return cards
    }

    /// Pure parser for the vedioList envelope. Testable without
    /// the network.
    static func cards(fromDirectory json: JSONValue) -> [BigoDirectoryCard] {
        guard json["code"].intValue == 0,
              json["data"]["resCode"].stringValue == "0" else { return [] }
        var seen = Set<String>()
        var cards: [BigoDirectoryCard] = []
        for row in json["data"]["data"].arrayValue {
            guard let card = card(fromDirectoryRow: row),
                  seen.insert(card.siteID).inserted else { continue }
            cards.append(card)
        }
        return cards
    }

    static func card(fromDirectoryRow row: JSONValue) -> BigoDirectoryCard? {
        guard let siteID = BigoRecipe.validateSiteID(row["bigo_id"].stringValue ?? ""),
              let owner = row["owner"].intValue, owner >= 1,
              let sid = row["sid"].intValue,
              let title = row["room_topic"].stringValue,
              let nickname = row["nick_name"].stringValue else { return nil }
        return BigoDirectoryCard(
            siteID: siteID,
            ownerID: owner,
            sid: sid,
            title: title,
            nickname: nickname,
            coverURL: row["cover_m"].stringValue,
            viewerCount: row["user_count"].intValue,
            isLocked: row["is_locked"].intValue == 1
        )
    }

    /// Pure mapper for a directory card. Testable without the network.
    static func room(fromCard card: BigoDirectoryCard) -> LiveRoom {
        LiveRoom(
            id: "bigo-\(card.siteID)",
            platform: .bigo,
            roomID: card.siteID,
            title: card.title.isEmpty ? card.nickname : card.title,
            anchorName: card.nickname,
            anchorAvatarURL: Self.imageURL(card.coverURL),
            coverURL: Self.imageURL(card.coverURL),
            categoryName: "Bigo Live",
            viewerCount: card.viewerCount ?? 0,
            isLive: true
        )
    }

    /// Local paging (1-based). Pure function.
    static func page<T>(_ values: [T], page: Int, size: Int) -> [T] {
        guard page >= 1, size >= 1 else { return [] }
        let start = (page - 1) * size
        guard start < values.count else { return [] }
        return Array(values[start..<min(start + size, values.count)])
    }

    // MARK: - Search (exact id/link, else snapshot filter)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, page >= 1 else { return [] }
        if let siteID = BigoRecipe.parseLinkOrSiteID(query) {
            // An exact id/link goes straight to the studio room.
            // A bare word that merely looks like an id (digits,
            // "_", ".", "-") is tried exactly first; anything else
            // is only a snapshot filter.
            let looksLikeID = query.contains("bigo.tv")
                || query.contains(where: { "0123456789_.-".contains($0) })
            if looksLikeID {
                if page == 1, let room = try? await exactRoom(siteID: siteID) {
                    return [room]
                }
                if query.contains("bigo.tv") { return [] }
            }
        }
        let needle = query.lowercased()
        let matches = (try await directory()).filter {
            !$0.isLocked
                && ($0.nickname.lowercased().contains(needle) || $0.title.lowercased().contains(needle))
        }
        return Self.page(matches, page: page, size: Self.pageSize).map(Self.room(fromCard:))
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: page)
    }

    private func exactRoom(siteID: String) async throws -> LiveRoom? {
        let studio = try await BigoRecipe.studioRoom(siteID: siteID, http: http)
        return Self.room(fromStudio: studio)
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let studio = try await BigoRecipe.studioRoom(siteID: roomID, http: http)
        return Self.room(fromStudio: studio)
    }

    /// Pure mapper for a studio room. Gated rooms come back with
    /// isLive false (they are shown, never played); a public room
    /// is live only when the server says alive AND hands over an
    /// hls_src. Testable without the network.
    static func room(fromStudio studio: BigoStudioRoom) -> LiveRoom {
        let isLive = studio.access == .public && studio.isAlive == true && studio.hlsURL != nil
        var room = LiveRoom(
            id: "bigo-\(studio.canonicalSiteID)",
            platform: .bigo,
            roomID: studio.canonicalSiteID,
            title: studio.title.isEmpty ? studio.nickname : studio.title,
            anchorName: studio.nickname,
            anchorAvatarURL: Self.imageURL(studio.avatarURL),
            coverURL: Self.imageURL(studio.snapshotURL.isEmpty ? studio.avatarURL : studio.snapshotURL),
            categoryName: studio.category.isEmpty ? "Bigo Live" : studio.category,
            viewerCount: 0,
            isLive: isLive
        )
        // Carry the media lease on the room so playURLs need not
        // re-run the token flow (Pure Live's LiveRoom.data).
        if let hls = studio.hlsURL {
            room.playDataJSON = "{\"hls\":\"\(hls.absoluteString)\",\"siteId\":\"\(studio.canonicalSiteID)\"}"
        }
        return room
    }

    // MARK: - Play URLs (the studio hls_src, verbatim)

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        if let carried = room.playDataJSON,
           let data = carried.data(using: .utf8),
           let json = JSONValue.parse(data),
           let hlsText = json["hls"].stringValue,
           let url = URL(string: hlsText) {
            return [PlayStream(url: url, quality: "live", line: "主线路", headers: BigoRecipe.headers)]
        }
        let studio = try await BigoRecipe.studioRoom(siteID: room.roomID, http: http)
        guard studio.access == .public, studio.isAlive == true,
              let url = studio.hlsURL else { return [] }
        return [PlayStream(url: url, quality: "live", line: "主线路", headers: BigoRecipe.headers)]
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return AsyncStream { continuation in
            let task = Task {
                // The chat channel needs the numeric room id + owner
                // id from the studio room; fetch them here (the
                // token flow runs once for this).
                guard let studio = try? await BigoRecipe.studioRoom(siteID: roomID, http: self.http),
                      studio.access == .public,
                      let numericRoomID = studio.roomID, !numericRoomID.isEmpty else {
                    continuation.finish()
                    return
                }
                let stream = BigoDanmaku.stream(
                    siteID: studio.canonicalSiteID,
                    ownerID: studio.ownerID,
                    roomID: numericRoomID
                )
                for await item in stream {
                    continuation.yield(item)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
#else
        return AsyncStream { $0.finish() }
#endif
    }
}

/// One row of the recommendation snapshot.
struct BigoDirectoryCard {
    let siteID: String
    let ownerID: Int
    let sid: Int
    let title: String
    let nickname: String
    let coverURL: String?
    let viewerCount: Int?
    let isLocked: Bool
}
