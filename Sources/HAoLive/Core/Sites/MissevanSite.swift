// MissevanSite.swift
// HAo Live — real 猫耳FM adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   categories  GET https://fm.missevan.com/api/v2/meta/data
//               -> {code: 0, info: {tabs: [{type: catalog/tag,
//                  catalog_id/tag_id, name, icon_url}]}} — tabs of
//               other types (e.g. list) carry no usable id and are
//               skipped. All responses are {code, info}; code != 0
//               is an error, 500030004 means the room does not exist.
//   list        GET /api/v2/chatroom/open/list?p={page}
//               [&catalog_id=|&tag_id=] (server page size 20)
//               -> {info: {pagination: {count, maxpage, p, pagesize},
//                  Datas: [{room_id, creator_id, name,
//                  creator_username, cover_url, creator_iconurl,
//                  catalog_name, announcement, status: {open},
//                  statistics: {score}}]}} — status.open == 1 is
//               live; the score is popularity, not viewers.
//   search      GET /api/v2/chatroom/search?s={keyword}&p={page}
//               &page_size=20 -> {info: {pagination, data: [...]}},
//               same row shape; offline creators are included.
//   detail/play GET /api/v2/live/{roomId}
//               -> {info: {room: {...same row...,
//                  channel: {flv_pull_url, hls_pull_url}}}} — the
//               pull URLs carry an `expires` signature query; they
//               are kept verbatim except for http -> https
//               normalization. Exactly one quality ("原画"): the HLS
//               line first, the FLV line second. Note: most 猫耳
//               broadcasts are audio-first (the video track is often
//               a 16x16 placeholder + AAC); the player handles the
//               actual tracks, the adapter does not guess.
// Danmaku: NOT implemented — Missevan's chat frames are brotli
// compressed (flag byte + little-endian length + brotli payload)
// and iOS/Foundation ships no brotli decoder, so danmakuStream
// keeps the protocol's honest empty default. No login anywhere.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MissevanSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .missevan
    private let http = HTTPClient.shared

    private static let apiBase = "https://fm.missevan.com/api/v2"
    private static let serverPageSize = 20

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        let info = try await get("meta/data")
        return Self.categories(fromMetaInfo: info)
    }

    /// Pure parser for the meta/data tabs. Only catalog/tag tabs
    /// carry an id the list endpoint accepts.
    static func categories(fromMetaInfo info: JSONValue) -> [LiveCategory] {
        var seen = Set<String>()
        var out: [LiveCategory] = []
        for tab in info["tabs"].arrayValue {
            let type = tab["type"].stringValue ?? ""
            guard type == "catalog" || type == "tag",
                  let id = tab["\(type)_id"].stringValue,
                  let name = tab["name"].stringValue, !name.isEmpty else { continue }
            let key = "\(type):\(id)"
            guard seen.insert(key).inserted else { continue }
            out.append(LiveCategory(
                id: "missevan-\(key)",
                platform: .missevan,
                name: name,
                iconName: nil,
                iconURL: Self.imageURL(tab["icon_url"].stringValue)
            ))
        }
        return out
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await list(page: 1, category: nil)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await list(page: page, category: nil)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await list(page: 1, category: category)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await list(page: page, category: category)
    }

    private func list(page: Int, category: LiveCategory?) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        var query = "p=\(page)"
        if let category, let (type, id) = Self.categoryParam(from: category.id) {
            query += "&\(type)_id=\(id)"
        }
        let info = try await get("chatroom/open/list?\(query)")
        let maxPage = info["pagination"]["maxpage"].intValue ?? 0
        guard page <= max(1, maxPage) else { return [] }
        return info["Datas"].arrayValue.compactMap { Self.room(fromRow: $0, liveOnly: true) }
    }

    /// "missevan-catalog:105" -> ("catalog", "105"); nil otherwise.
    static func categoryParam(from categoryID: String) -> (String, String)? {
        guard categoryID.hasPrefix("missevan-") else { return nil }
        let rest = String(categoryID.dropFirst("missevan-".count))
        let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, (parts[0] == "catalog" || parts[0] == "tag"),
              !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Pure parser for one list/search/detail row. `liveOnly` drops
    /// offline rows (directory use); search keeps them with
    /// isLive == false. A row without a room id is never a room.
    static func room(fromRow row: JSONValue, liveOnly: Bool = false) -> LiveRoom? {
        guard let roomID = row["room_id"].stringValue, !roomID.isEmpty else { return nil }
        let open = row["status"]["open"].intValue ?? 0
        guard open == 0 || open == 1 else { return nil }
        let isLive = open == 1
        guard !liveOnly || isLive else { return nil }
        return LiveRoom(
            id: "missevan-\(roomID)",
            platform: .missevan,
            roomID: roomID,
            title: row["name"].stringValue ?? "",
            anchorName: row["creator_username"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(row["creator_iconurl"].stringValue),
            coverURL: Self.imageURL(row["cover_url"].stringValue),
            categoryName: row["catalog_name"].stringValue,
            viewerCount: row["statistics"]["score"].intValue ?? 0,
            isLive: isLive
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
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, page >= 1 else { return [] }
        // A bare room id (or a fm.missevan.com/live/{id} link) resolves
        // directly to that room's detail.
        if let roomID = Self.roomID(from: term), page == 1 {
            if let room = try? await roomDetail(roomID: roomID) {
                return [room]
            }
            return []
        }
        guard !term.contains("://") else { return [] }
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let info = try await get("chatroom/search?s=\(encoded)&p=\(page)&page_size=\(Self.serverPageSize)")
        let maxPage = info["pagination"]["maxpage"].intValue ?? 0
        guard page <= max(1, maxPage) else { return [] }
        return info["data"].arrayValue.compactMap { Self.room(fromRow: $0) }
    }

    /// Numeric room id, or the id from a fm.missevan.com/live/{id} URL.
    static func roomID(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[1-9][0-9]{0,17}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              url.host?.lowercased() == "fm.missevan.com" else { return nil }
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count == 2, segments[0] == "live",
              segments[1].range(of: #"^[1-9][0-9]{0,17}$"#, options: .regularExpression) != nil else { return nil }
        return segments[1]
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let detail = try await fetchDetail(roomID: roomID)
        return detail.room
    }

    /// Detail row + channel URLs. The channel URLs are only valid
    /// while the room is live; offline rooms never expose them.
    struct DetailResult {
        var room: LiveRoom
        var flvURL: String?
        var hlsURL: String?
    }

    private func fetchDetail(roomID: String) async throws -> DetailResult {
        guard Self.roomID(from: roomID) != nil else { throw LiveSiteError.roomNotFound(roomID) }
        let info = try await get("live/\(roomID)")
        guard let parsedRoom = Self.room(fromRow: info["room"]) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        var room = parsedRoom
        let creator = info["creator"]
        if !creator.isNull {
            if let avatar = creator["iconurl"].stringValue {
                room.anchorAvatarURL = Self.imageURL(avatar)
            }
        }
        guard room.isLive else { return DetailResult(room: room, flvURL: nil, hlsURL: nil) }
        let channel = info["room"]["channel"]
        return DetailResult(
            room: room,
            flvURL: channel["flv_pull_url"].stringValue,
            hlsURL: channel["hls_pull_url"].stringValue
        )
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let detail = try await fetchDetail(roomID: room.roomID)
        guard detail.room.isLive else { return [] }
        let headers = PlaybackHeaders.headers(platform: .missevan, roomID: room.roomID)
        var out: [PlayStream] = []
        // HLS first (the engine prefers it), FLV second. Signed
        // query parameters are kept verbatim; only the scheme is
        // normalized to https (see mediaURL).
        if let hls = detail.hlsURL, let url = Self.mediaURL(hls, kind: "hls") {
            out.append(PlayStream(
                url: url, quality: "原画", line: "HLS线路", headers: headers,
                expiresAt: Self.expiresAt(of: url)
            ))
        }
        if let flv = detail.flvURL, let url = Self.mediaURL(flv, kind: "flv") {
            out.append(PlayStream(
                url: url, quality: "原画", line: "FLV线路", headers: headers,
                expiresAt: Self.expiresAt(of: url)
            ))
        }
        return out
    }

    /// Signed pull URL, verbatim except http -> https. Nil unless the
    /// URL is a *.bilivideo.com HLS (.m3u8) / FLV (.flv) address.
    static func mediaURL(_ input: String, kind: String) -> URL? {
        guard kind == "hls" || kind == "flv",
              var components = URLComponents(string: input),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host, host.hasSuffix(".bilivideo.com"),
              components.user == nil, components.fragment == nil else { return nil }
        let expectedSuffix = kind == "hls" ? ".m3u8" : ".flv"
        guard components.path.hasSuffix(expectedSuffix) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The `expires` query value is an absolute Unix timestamp.
    static func expiresAt(of url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "expires" })?.value,
              let seconds = Double(raw), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - API plumbing

    /// GET an /api/v2 path; returns the `info` object. Throws
    /// roomNotFound on the API's nonexistent-room code.
    private func get(_ path: String) async throws -> JSONValue {
        let json = try await http.getJSON("\(Self.apiBase)/\(path)")
        guard let code = json["code"].intValue else { throw LiveSiteError.invalidResponse }
        if code == 500030004 { throw LiveSiteError.roomNotFound(path) }
        guard code == 0 else { throw LiveSiteError.message("猫耳FM返回错误 \(code)") }
        return json["info"]
    }
}
