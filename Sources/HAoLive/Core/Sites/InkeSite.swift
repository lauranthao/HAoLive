// InkeSite.swift
// HAo Live — Inke (映客) adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   top     GET webapi.busi.inke.cn/web/Live_top_pc
//           -> {error_code: 0, data: {list: [{uid, live_id, nick,
//              portrait, stream_addr}]}} (8 rows)
//   channel GET webapi.busi.inke.cn/web/Live_channel_pc
//           -> {error_code: 0, data: {list: [{tab_key,
//              channel_name, list: [{uid, live_id, nick, portrait,
//              stream_addr}]}]}} (6 groups: 音乐/舞蹈/新颜/校园/
//              男神/...)
//   detail  GET webapi.busi.inke.cn/web/live_share_pc?uid=
//           -> {error_code: 0, data: {liveid, live_name, status,
//              media_info: {inke_id, nick, portrait}}}
//           error_code 1099999920 = no current broadcast (offline).
// There is NO site-wide list and NO server search: the two
// showcases above are the whole catalogue, paging is a local
// slice, and search is a local nickname filter over them.
// Playback is FLV only; the stream address lives in the showcase
// rows (Live_top_pc / Live_hot_pc / Live_channel_pc) and is used
// VERBATIM — signed query included, never re-built. One tier.
// No danmaku on this platform (no danmaku file, default empty
// stream).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class InkeSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .inke
    private let http = HTTPClient.shared

    private static let apiBase = "https://webapi.busi.inke.cn/web"
    private static let origin = "https://www.inke.cn"
    private static let playHeaders: [String: String] = [
        "Referer": "\(origin)/",
        "Origin": origin,
        "User-Agent": "Mozilla/5.0",
    ]
    private static let pageSize = 30

    // MARK: - Lists

    /// The channel groups are the platform's only category tree.
    func categories() async throws -> [LiveCategory] {
        let groups = try await channelGroups()
        return groups.map { group in
            LiveCategory(
                id: "inke-\(group.key)",
                platform: .inke,
                name: group.name,
                iconName: nil,
                iconURL: nil
            )
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await slicedRooms(page: 1, category: nil)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await slicedRooms(page: page, category: nil)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await slicedRooms(page: 1, category: category)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await slicedRooms(page: page, category: category)
    }

    /// One finite showcase, sliced locally (page 1-based).
    private func slicedRooms(page: Int, category: LiveCategory?) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let rows: [JSONValue]
        if let category {
            let key = category.id.hasPrefix("inke-")
                ? String(category.id.dropFirst("inke-".count)) : category.id
            let groups = try await channelGroups()
            guard let match = groups.first(where: { $0.key == key }) else { return [] }
            rows = match.rows
        } else {
            rows = try await topRows()
        }
        let rooms = dedupedRooms(fromRows: rows)
        let start = (page - 1) * Self.pageSize
        guard start < rooms.count else { return [] }
        return Array(rooms[start..<min(start + Self.pageSize, rooms.count)])
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

    /// No server search: a bare numeric UID resolves to that
    /// anchor's room; anything else filters the two showcases by
    /// nickname (local, case-insensitive). Cannot discover anchors
    /// outside the showcases.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, page >= 1 else { return [] }
        if query.allSatisfy({ $0.isNumber }), !query.hasPrefix("0") {
            guard page == 1,
                  let room = try? await roomDetail(roomID: query),
                  room.isLive else { return [] }
            return [room]
        }
        let lowered = query.lowercased()
        var rows = try await topRows()
        for group in try await channelGroups() {
            rows.append(contentsOf: group.rows)
        }
        let matches = dedupedRooms(fromRows: rows).filter {
            $0.anchorName.lowercased().contains(lowered)
        }
        let pageSize = 20
        let start = (page - 1) * pageSize
        guard start < matches.count else { return [] }
        return Array(matches[start..<min(start + pageSize, matches.count)])
    }

    // MARK: - Room detail

    /// UID -> current broadcast. error_code 1099999920 means the
    /// anchor is offline (an offline room, not an error).
    func roomDetail(roomID: String) async throws -> LiveRoom {
        let uid = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, uid.allSatisfy({ $0.isNumber }) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let data = try await get(path: "live_share_pc", query: ["uid": uid])
        guard let liveID = data["liveid"].stringValue, !liveID.isEmpty,
              data["status"].intValue == 1 || data["status"].stringValue == "1" else {
            return offlineRoom(uid: uid)
        }
        let owner = data["media_info"]
        let nick = owner["nick"].stringValue ?? ""
        guard !nick.isEmpty, owner["inke_id"].stringValue == uid else {
            throw LiveSiteError.invalidResponse
        }
        let title = HaoText.firstNonEmpty(data["live_name"].stringValue, nick) ?? nick
        return LiveRoom(
            id: "inke-\(uid)",
            platform: .inke,
            roomID: uid,
            title: title,
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(owner["portrait"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(
                data["portrait"].stringValue, owner["portrait"].stringValue)),
            categoryName: nil,
            viewerCount: 0,
            isLive: true,
            playDataJSON: "{\"liveId\":\"\(liveID)\"}"
        )
    }

    private func offlineRoom(uid: String) -> LiveRoom {
        LiveRoom(
            id: "inke-\(uid)",
            platform: .inke,
            roomID: uid,
            title: "",
            anchorName: "",
            anchorAvatarURL: nil,
            coverURL: nil,
            categoryName: nil,
            viewerCount: 0,
            isLive: false
        )
    }

    // MARK: - Play URLs

    /// FLV only, one tier. The signed stream address is used
    /// verbatim. List rooms carry it on playDataJSON (fast path);
    /// otherwise the three showcases are scanned for the
    /// uid + live_id match.
    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let uid = room.roomID
        if let carried = Self.carriedStream(from: room.playDataJSON),
           let url = Self.streamURL(carried.address, liveID: carried.liveID) {
            return [PlayStream(url: url, quality: "原画", line: "FLV",
                               headers: PlaybackHeaders.headers(platform: .inke, roomID: uid))]
        }
        let liveID: String
        if let carried = Self.carriedStream(from: room.playDataJSON) {
            liveID = carried.liveID
        } else {
            let detail = try await roomDetail(roomID: uid)
            guard detail.isLive,
                  let carried = Self.carriedStream(from: detail.playDataJSON) else { return [] }
            liveID = carried.liveID
        }
        guard let address = try await showcaseStream(uid: uid, liveID: liveID),
              let url = Self.streamURL(address, liveID: liveID) else { return [] }
        return [PlayStream(url: url, quality: "原画", line: "FLV",
                           headers: PlaybackHeaders.headers(platform: .inke, roomID: uid))]
    }

    /// The stream address + live id carried on playDataJSON.
    static func carriedStream(from playDataJSON: String?) -> (liveID: String, address: String?)? {
        guard let text = playDataJSON,
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data),
              let liveID = json["liveId"].stringValue, !liveID.isEmpty else { return nil }
        return (liveID: liveID, address: json["streamAddr"].stringValue)
    }

    /// Validate a signed FLV address (host + /live/{liveId}_t.flv)
    /// and return it VERBATIM. Nil when it is not an Inke pull URL.
    /// Testable without the network.
    static func streamURL(_ string: String?, liveID: String) -> URL? {
        guard let string, !string.isEmpty,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host == "live-pull-ws.ikstatic.cn",
              url.path == "/live/\(liveID)_t.flv" else { return nil }
        return url
    }

    /// Scan Live_top_pc, Live_hot_pc and Live_channel_pc for the
    /// uid + live_id row and return its stream_addr.
    private func showcaseStream(uid: String, liveID: String) async throws -> String? {
        for path in ["Live_top_pc", "Live_hot_pc", "Live_channel_pc"] {
            let data = try await get(path: path)
            let groups: [[JSONValue]]
            switch path {
            case "Live_hot_pc":
                // data.list is an object whose values are row arrays.
                groups = data["list"].objectValue.values.map { $0.arrayValue }
            case "Live_channel_pc":
                groups = data["list"].arrayValue.map { $0["list"].arrayValue }
            default:
                groups = [data["list"].arrayValue]
            }
            for rows in groups {
                for row in rows {
                    guard row["uid"].stringValue == uid,
                          row["live_id"].stringValue == liveID,
                          let address = row["stream_addr"].stringValue, !address.isEmpty else { continue }
                    return address
                }
            }
        }
        return nil
    }

    // MARK: - Showcase fetching

    /// GET one web API endpoint; returns the inner `data` object.
    /// error_code 1099999920 is only meaningful on live_share_pc
    /// (offline anchor) — there it is surfaced as an empty data
    /// object so roomDetail can build the offline room.
    private func get(path: String, query: [String: String] = [:]) async throws -> JSONValue {
        var url = "\(Self.apiBase)/\(path)"
        if !query.isEmpty {
            let items = query.map { key, value in
                let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(v)"
            }.joined(separator: "&")
            url += "?\(items)"
        }
        let json = try await http.getJSON(url, headers: Self.playHeaders)
        guard let code = json["error_code"].intValue else {
            throw LiveSiteError.invalidResponse
        }
        if code == 1099999920, path == "live_share_pc" {
            return JSONValue.null
        }
        guard code == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]
    }

    private func topRows() async throws -> [JSONValue] {
        let data = try await get(path: "Live_top_pc")
        return data["list"].arrayValue
    }

    struct ChannelGroup {
        let key: String
        let name: String
        let rows: [JSONValue]
    }

    private func channelGroups() async throws -> [ChannelGroup] {
        let data = try await get(path: "Live_channel_pc")
        return data["list"].arrayValue.compactMap { group in
            guard let key = group["tab_key"].stringValue, !key.isEmpty,
                  let name = group["channel_name"].stringValue, !name.isEmpty else { return nil }
            return ChannelGroup(key: key, name: name, rows: group["list"].arrayValue)
        }
    }

    /// Pure parser for one showcase row. Nil when the row has no
    /// usable uid / live_id / nick. Testable without the network.
    static func room(fromShowcaseRow row: JSONValue) -> LiveRoom? {
        guard let uid = row["uid"].stringValue, !uid.isEmpty,
              let liveID = row["live_id"].stringValue, !liveID.isEmpty,
              let nick = row["nick"].stringValue, !nick.isEmpty else { return nil }
        var playData = "{\"liveId\":\"\(liveID)\""
        if let address = row["stream_addr"].stringValue, !address.isEmpty {
            let escaped = address
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            playData += ",\"streamAddr\":\"\(escaped)\""
        }
        playData += "}"
        return LiveRoom(
            id: "inke-\(uid)",
            platform: .inke,
            roomID: uid,
            title: nick,
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(row["portrait"].stringValue),
            coverURL: Self.imageURL(row["portrait"].stringValue),
            categoryName: nil,
            viewerCount: 0,
            isLive: true,
            playDataJSON: playData
        )
    }

    private func dedupedRooms(fromRows rows: [JSONValue]) -> [LiveRoom] {
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for row in rows {
            guard let room = Self.room(fromShowcaseRow: row),
                  seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
        }
        return rooms
    }
}
