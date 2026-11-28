// Fc2Site.swift
// HAo Live — real FC2 Live adapter (anonymous, no login).
// Pure Live's fc2_site.dart / fc2_api.dart /
// fc2_control_session.dart, re-implemented from scratch for
// HAo Live. Endpoints verified live from this VM 2026-11-28:
//   list    POST live.fc2.com/contents/allchannellist.php
//           (empty form) -> HTTP 200, 65 channels, 51 public
//           (type==1, pay==0, tid==0, login==0). Rows carry id,
//           name, title, image (live-storage.fc2.com thumb),
//           category 0-99, type, pay, tid, login, count, total,
//           start_time (millis), sex, lang.
//   detail  POST /api/memberApi.php (channel=1&profile=1&user=1&
//           streamid=<id>) -> status 1, channel_data /
//           profile_data: is_publish, is_limited, fee,
//           ticketid, ticket_only, login_only, version.
//   play    POST /api/getControlServer.php -> control seat,
//           then a control WebSocket reads the HLS master
//           (see Fc2ControlSession.swift). One quality "auto".
//   search  No server search. Exact channel id / link goes to
//           memberApi; otherwise the snapshot is filtered
//           locally (channel id / user / title / category).
//   danmaku Fc2Danmaku.swift (comment channel on the same
//           control WebSocket). Live WS verified on this VM.
// Categories are the FC2 category tree (Pure Live's
// Fc2Site.categories): all + 1 Idle Chat, 2 Game/Work
// (matches 2 or 3), 4 Video, 9 Audio, 5 Other. Local paging,
// 20 per page. Gated rooms are dropped from the directory and
// never listed as playable.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class Fc2Site: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .fc2live
    private let http = HTTPClient.shared

    private static let listURL = "https://live.fc2.com/contents/allchannellist.php"
    private static let pageSize = 20

    /// 20-second snapshot cache (Pure Live's Fc2Site cache).
    private var cachedDirectory: [Fc2Room]?
    private var cachedDirectoryAt: Date?

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        [
            LiveCategory(id: "fc2-0", platform: .fc2live, name: "全部", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-1", platform: .fc2live, name: "Idle Chat", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-2", platform: .fc2live, name: "Game / Work", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-4", platform: .fc2live, name: "Video", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-9", platform: .fc2live, name: "Audio", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-5", platform: .fc2live, name: "Other", iconName: nil, iconURL: nil),
        ]
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        Self.page(try await directory(), page: page, size: Self.pageSize).map(Self.room(fromFc2:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard let categoryID = Self.categoryID(category.id) else { return [] }
        let filtered = (try await directory()).filter {
            categoryID == 0 || $0.categoryID == categoryID
                || (categoryID == 2 && $0.categoryID == 3)
        }
        return Self.page(filtered, page: page, size: Self.pageSize).map(Self.room(fromFc2:))
    }

    /// The directory snapshot, cached 20 s. Restricted rooms are
    /// dropped here — they are never listed as playable.
    private func directory() async throws -> [Fc2Room] {
        if let cached = cachedDirectory, let at = cachedDirectoryAt,
           Date().timeIntervalSince(at) < 20 {
            return cached
        }
        let data = try await http.postForm(Self.listURL, fields: [:], headers: Fc2ControlSession.headers)
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        let rooms = Fc2ControlSession.parseDirectory(json).filter { $0.restriction == nil }
        cachedDirectory = rooms
        cachedDirectoryAt = Date()
        return rooms
    }

    /// Pure mapper for an FC2 room. Testable without the network.
    static func room(fromFc2 room: Fc2Room) -> LiveRoom {
        LiveRoom(
            id: "fc2-\(room.channelID)",
            platform: .fc2live,
            roomID: room.channelID,
            title: room.title.isEmpty ? room.userName : room.title,
            anchorName: room.userName,
            anchorAvatarURL: Self.imageURL(room.coverURL),
            coverURL: Self.imageURL(room.coverURL),
            categoryName: room.categoryName,
            viewerCount: room.currentViewers ?? 0,
            isLive: room.state == .live
        )
    }

    /// Local paging (1-based). Pure function.
    static func page<T>(_ values: [T], page: Int, size: Int) -> [T] {
        guard page >= 1, size >= 1 else { return [] }
        let start = (page - 1) * size
        guard start < values.count else { return [] }
        return Array(values[start..<min(start + size, values.count)])
    }

    /// "fc2-<n>" -> the category id, or nil when not an FC2 category.
    static func categoryID(_ id: String) -> Int? {
        guard id.hasPrefix("fc2-"), let value = Int(id.dropFirst(4)),
              [0, 1, 2, 4, 9, 5].contains(value) else { return nil }
        return value
    }

    // MARK: - Search (exact channel id/link, else snapshot filter)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, page >= 1 else { return [] }
        if let channelID = Fc2ControlSession.parseChannelID(query) {
            if page == 1, let room = try? await exactRoom(channelID: channelID) {
                return [room]
            }
            if query.contains("fc2.com") { return [] }
        }
        let needle = query.lowercased()
        let matches = (try await directory()).filter {
            $0.channelID.contains(needle)
                || $0.userName.lowercased().contains(needle)
                || $0.title.lowercased().contains(needle)
                || $0.categoryName.lowercased().contains(needle)
        }
        return Self.page(matches, page: page, size: Self.pageSize).map(Self.room(fromFc2:))
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: page)
    }

    private func exactRoom(channelID: String) async throws -> LiveRoom? {
        let (room, _) = try await Fc2ControlSession.member(channelID: channelID, http: http)
        return Self.room(fromFc2: room)
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let (room, _) = try await Fc2ControlSession.member(channelID: roomID, http: http)
        return Self.room(fromFc2: room)
    }

    // MARK: - Play URLs (control session -> HLS master, verbatim)

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
#if os(Linux)
        throw LiveSiteError.notImplemented
#else
        let (master, cookie) = try await Fc2ControlSession.fetchMaster(channelID: room.roomID, http: http)
        // The shared default headers already carry the FC2
        // Origin / Referer (platform webBase); the seat cookie
        // rides along on the stream.
        let headers = PlaybackHeaders.headers(platform: .fc2live, roomID: room.roomID, cookie: cookie)
        return [PlayStream(url: master, quality: "auto", line: "主线路", headers: headers)]
#endif
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return Fc2Danmaku.stream(channelID: roomID, http: http)
#else
        return AsyncStream { $0.finish() }
#endif
    }
}
