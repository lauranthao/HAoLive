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
//           then a control WebSocket reads the HLS playlists
//           (see Fc2ControlSession.swift). Tiers 50/40/30/20/10
//           plus auto, from all three playlist families
//           (low / high / middle latency). The control socket is
//           held for the whole playback (ref Fc2LiveControl):
//           the media server refuses variant playlists once the
//           socket is gone, and a control_disconnection (grant
//           expired, code 4500) ends it — the owner takes a new
//           grant. One quality "auto" alone was the old shape.
//   search  No server search. Exact channel id / link goes to
//           memberApi; otherwise the snapshot is filtered
//           locally (channel id / user / title / category).
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

    /// The held control seat of the channel being played (ref
    /// Fc2LiveControl: kept open for the whole playback). The site
    /// is a SiteRegistry singleton, so one control is held at a
    /// time; opening another channel's control closes this one,
    /// and the room view closes it on exit.
#if !os(Linux)
    private let controlLock = NSLock()
    private var heldControl: Fc2ControlSession.Fc2Control?
#endif

    func endPlaybackSession() {
#if !os(Linux)
        let control: Fc2ControlSession.Fc2Control? = {
            controlLock.lock()
            defer { controlLock.unlock() }
            let control = heldControl
            heldControl = nil
            return control
        }()
        control?.close()
#endif
    }

    private static let listURL = "https://live.fc2.com/contents/allchannellist.php"
    private static let pageSize = 20

    /// 20-second snapshot cache (Pure Live's Fc2Site cache).
    private var cachedDirectory: [Fc2Room]?
    private var cachedDirectoryAt: Date?

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        // Ref Fc2LiveApi.areaNames (3.x's zh.json).
        [
            LiveCategory(id: "fc2-0", platform: .fc2live, name: "全部公开直播", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-1", platform: .fc2live, name: "闲聊", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-2", platform: .fc2live, name: "游戏 / 作业", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-4", platform: .fc2live, name: "视频", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-9", platform: .fc2live, name: "音频", iconName: nil, iconURL: nil),
            LiveCategory(id: "fc2-5", platform: .fc2live, name: "其他", iconName: nil, iconURL: nil),
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
    /// Ref Fc2LiveApi.room: the owner's picture as the avatar,
    /// else the cover; live when the state is not offline
    /// (restricted rooms are live and marked, not offline).
    static func room(fromFc2 room: Fc2Room) -> LiveRoom {
        LiveRoom(
            id: "fc2-\(room.channelID)",
            platform: .fc2live,
            roomID: room.channelID,
            title: room.title.isEmpty ? room.userName : room.title,
            anchorName: room.userName,
            anchorAvatarURL: Self.imageURL(room.avatarURL.isEmpty ? room.coverURL : room.avatarURL),
            coverURL: Self.imageURL(room.coverURL),
            categoryName: room.categoryName,
            viewerCount: room.currentViewers ?? 0,
            isLive: room.state != .offline
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
                || Fc2ControlSession.legacyAreaName($0.categoryID).lowercased().contains(needle)
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

    // MARK: - Play URLs (control session -> HLS playlists, held)

#if !os(Linux)
    /// The control of `channelID`: the held one when it is alive
    /// (quality switches and lease refreshes read the playlists
    /// it already announced, no new grant), else a fresh grant +
    /// control — the old one is closed first (ref: a control
    /// never reconnects with a used grant).
    private func heldControl(for channelID: String) async throws -> Fc2ControlSession.Fc2Control {
        let existing: Fc2ControlSession.Fc2Control? = {
            controlLock.lock()
            defer { controlLock.unlock() }
            return heldControl
        }()
        if let existing, existing.channelID == channelID, existing.isAlive {
            return existing
        }
        existing?.close()
        let grant = try await Fc2ControlSession.controlGrant(channelID: channelID, http: http)
        let fresh = try await Fc2ControlSession.Fc2Control.open(grant: grant)
        controlLock.lock()
        heldControl = fresh
        controlLock.unlock()
        return fresh
    }
#endif

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
#if os(Linux)
        throw LiveSiteError.notImplemented
#else
        let control = try await heldControl(for: room.roomID)
        // Every quality the channel offers (ref Fc2LiveApi.
        // qualitiesOf): tiers best first, then auto. Each plays
        // the playlist the control announced for it (ref
        // Fc2LiveApi.playlistFor) — the old code read only the
        // mode-0 master and offered a single "auto" line, so
        // channels whose answer lists tiers never showed them.
        // Media headers are the reference's (UA / origin /
        // channel-page referer, no cookie — the control session
        // authorises server-side). There is no known expiry on
        // these signed URLs, so no expiresAt: when the control
        // ends mid-stream the engine fails over and the sweep
        // re-resolves once with a fresh grant.
        let ids = Fc2ControlSession.qualitiesOf(control.playlists)
        guard !ids.isEmpty else { throw LiveSiteError.invalidResponse }
        var streams: [PlayStream] = []
        for id in ids {
            guard let found = Fc2ControlSession.playlistFor(control.playlists, quality: id) else { continue }
            streams.append(PlayStream(
                url: found.url,
                quality: Fc2ControlSession.qualityLabel(for: found.quality),
                line: "主线路",
                headers: Fc2ControlSession.mediaHeaders(channelID: room.roomID),
                formatOverride: "hls"
            ))
        }
        guard !streams.isEmpty else { throw LiveSiteError.invalidResponse }
        return streams
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
