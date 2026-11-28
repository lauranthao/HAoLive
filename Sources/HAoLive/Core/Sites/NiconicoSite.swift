// NiconicoSite.swift
// HAo Live — real niconico adapter (anonymous, no login).
// Pure Live's niconico_site.dart / niconico_directory.dart /
// niconico_watch.dart, re-implemented from scratch for HAo Live.
// Endpoints verified live from this VM 2026-11-28 (HTTP 200):
//   list    GET live.nicovideo.jp/front/api/pages/recent/v1/programs
//           ?tab=<tab>&offset=<page-1>&sortOrder=recentDesc
//           -> meta{statusCode 200, errorCode OK, totalCount} +
//           data[] {id (lv…), title, listingThumbnail,
//           watchPageUrl, providerType (community/channel/official),
//           liveCycle ON_AIR, programProvider{id, name, icon},
//           socialGroup{id (ch…), name, thumbnailUrl},
//           statistics{watchCount}} (70 per page; recent total
//           212 on the common tab at probe time)
//   search  GET …/front/api/pages/search/v1/programs
//           ?keyword=&column=main&status=onair&page=&disableGrouping=true
//           -> data{totalCount, programs[] {nicoliveProgramId,
//           status ON_AIR, title, supplier{name, programProviderId,
//           icons{uri150x150}}, listingThumbnail,
//           statistics{watchCount}}} (40 per page; 174 hits for
//           ゲーム at probe time)
//   detail  GET live.nicovideo.jp/watch/{lv…} — the page embeds
//           one <script id="embedded-data" data-props="…"> JSON
//           (see NiconicoMaster.NiconicoWatch.parsePage). Broadcaster
//           ids (user/… / ch…) resolve through the page's canonical
//           link first.
//   play    No direct URL — watch session + master relay, see
//           NiconicoMaster.swift (verified live end-to-end).
//   danmaku None (niconico comments ride a different system;
//           Pure Live ships EmptyDanmaku for this platform).
//
// Tabs are the fixed recent tabs (NiconicoDirectory.categories):
// common / try / live / req / face / totu / vtuber. They are
// exposed as categories with their tab id as the name — the
// reference gives no display names, and inventing Japanese labels
// for them would be guessing.
// Access: loginRequired / regionRestricted programs are never
// played (roomDetail reports them as an error with the platform's
// own meaning); the list only ever contains ON_AIR programs.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class NiconicoSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .niconico
    private let http = HTTPClient.shared

    private static let origin = "https://live.nicovideo.jp"

    /// Fixed recent tabs (Pure Live's NiconicoDirectory.categories).
    static let tabs = ["common", "try", "live", "req", "face", "totu", "vtuber"]

    private static let recentSize = 70
    private static let searchSize = 40

    private var headers: [String: String] {
        ["User-Agent": "Mozilla/5.0", "Referer": "\(Self.origin)/"]
    }

    // MARK: - Categories (fixed tabs)

    func categories() async throws -> [LiveCategory] {
        Self.tabs.map { tab in
            LiveCategory(id: "niconico-\(tab)", platform: .niconico, name: tab, iconName: nil, iconURL: nil)
        }
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await recent(tab: "common", page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let tab = category.id.hasPrefix("niconico-") ? String(category.id.dropFirst("niconico-".count)) : category.id
        guard Self.tabs.contains(tab) else { return [] }
        return try await recent(tab: tab, page: page)
    }

    private func recent(tab: String, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let url = "\(Self.origin)/front/api/pages/recent/v1/programs?tab=\(tab)&offset=\(page - 1)&sortOrder=recentDesc"
        let json = try await http.getJSON(url, headers: headers)
        guard json["meta"]["statusCode"].intValue == 200,
              json["meta"]["errorCode"].stringValue == "OK" else {
            throw LiveSiteError.invalidResponse
        }
        return Self.rooms(fromRecentRows: json["data"].arrayValue)
    }

    /// Pure parser for recent-list rows. Rows that fail the
    /// reference's identity checks (id vs watchPageUrl, ON_AIR,
    /// providerType) are skipped, not fatal — one bad row must not
    /// empty the whole list. Testable without the network.
    static func rooms(fromRecentRows rows: [JSONValue]) -> [LiveRoom] {
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for row in rows {
            guard let room = room(fromRecentRow: row),
                  seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
        }
        return rooms
    }

    static func room(fromRecentRow row: JSONValue) -> LiveRoom? {
        guard let id = row["id"].stringValue,
              NiconicoWatch.isProgramID(id),
              NiconicoWatch.parseInput(row["watchPageUrl"].stringValue ?? "") == id,
              row["liveCycle"].stringValue == "ON_AIR",
              ["community", "channel", "official"].contains(row["providerType"].stringValue ?? "") else {
            return nil
        }
        let provider = row["programProvider"]
        let social = row["socialGroup"]
        let nick = provider["name"].stringValue ?? social["name"].stringValue ?? ""
        let icon = provider["icon"].stringValue ?? social["thumbnailUrl"].stringValue
        let roomID = roomIDOf(
            programID: id,
            providerType: row["providerType"].stringValue ?? "",
            providerID: provider["id"].stringValue,
            channelID: social["id"].stringValue
        )
        return LiveRoom(
            id: "niconico-\(id)",
            platform: .niconico,
            roomID: roomID,
            title: row["title"].stringValue ?? "",
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(NiconicoWatch.publicImage(icon)),
            coverURL: Self.imageURL(
                NiconicoWatch.publicImage(row["flippedListingThumbnail"].stringValue)
                    ?? NiconicoWatch.publicImage(row["listingThumbnail"].stringValue)
            ),
            categoryName: nil,
            viewerCount: row["statistics"]["watchCount"].intValue ?? 0,
            isLive: true
        )
    }

    /// The room id a list row is known by: a user/community
    /// program is its broadcaster (user/<id>), a channel program
    /// is its channel (ch…), anything else is the program id.
    static func roomIDOf(programID: String, providerType: String, providerID: String?, channelID: String?) -> String {
        if (providerType == "community" || providerType == "user"),
           let user = providerID,
           user.range(of: #"^[1-9][0-9]{0,17}$"#, options: .regularExpression) != nil {
            return "user/\(user)"
        }
        if providerType == "channel",
           let channel = channelID,
           NiconicoWatch.isBroadcasterRoomID(channel) {
            return channel
        }
        return programID
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, page >= 1 else { return [] }
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let url = "\(Self.origin)/front/api/pages/search/v1/programs?keyword=\(encoded)&column=main&status=onair&page=\(page)&disableGrouping=true"
        let json = try await http.getJSON(url, headers: headers)
        guard json["meta"]["statusCode"].intValue == 200,
              json["meta"]["errorCode"].stringValue == "OK" else {
            throw LiveSiteError.invalidResponse
        }
        return Self.rooms(fromSearchRows: json["data"]["programs"].arrayValue)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: page)
    }

    /// Pure parser for search rows. Testable without the network.
    static func rooms(fromSearchRows rows: [JSONValue]) -> [LiveRoom] {
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for row in rows {
            guard let room = room(fromSearchRow: row),
                  seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
        }
        return rooms
    }

    static func room(fromSearchRow row: JSONValue) -> LiveRoom? {
        guard let id = row["nicoliveProgramId"].stringValue,
              NiconicoWatch.isProgramID(id),
              row["status"].stringValue == "ON_AIR" else { return nil }
        let supplier = row["supplier"]
        let nick = supplier["name"].stringValue ?? ""
        return LiveRoom(
            id: "niconico-\(id)",
            platform: .niconico,
            roomID: id,
            title: row["title"].stringValue ?? "",
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(NiconicoWatch.publicImage(supplier["icons"]["uri150x150"].stringValue)),
            coverURL: Self.imageURL(
                NiconicoWatch.publicImage(row["flippedListingThumbnail"].stringValue)
                    ?? NiconicoWatch.publicImage(row["listingThumbnail"].stringValue)
            ),
            categoryName: nil,
            viewerCount: row["statistics"]["watchCount"].intValue ?? 0,
            isLive: true
        )
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let watch = try await NiconicoMaster.fetchWatch(programOrRoomID: roomID, http: http)
        switch watch.access {
        case .loginRequired:
            throw LiveSiteError.message("该节目需要登录后才能观看")
        case .regionRestricted:
            throw LiveSiteError.message("该节目在当前地区无法观看")
        case .denied:
            throw LiveSiteError.message("该节目暂时无法观看")
        case .allowed:
            break
        }
        return LiveRoom(
            id: "niconico-\(watch.programID)",
            platform: .niconico,
            roomID: roomID,
            title: watch.title,
            anchorName: watch.broadcaster,
            anchorAvatarURL: Self.imageURL(watch.avatarURL),
            coverURL: Self.imageURL(watch.coverURL),
            categoryName: nil,
            viewerCount: watch.watchCount ?? 0,
            isLive: watch.status == .onAir
        )
    }

    // MARK: - Play URLs (watch session + master relay)

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let programID: String
        if NiconicoWatch.isProgramID(room.roomID) {
            programID = room.roomID
        } else {
            // Broadcaster ids resolve to the current program first.
            let watch = try await NiconicoMaster.fetchWatch(programOrRoomID: room.roomID, http: http)
            programID = watch.programID
        }
        let watch = try await NiconicoMaster.fetchWatch(programOrRoomID: programID, http: http)
#if !os(Linux)
        let (variants, cookieHeader) = try await NiconicoMaster.fetchVariants(watch: watch, http: http)
        let headers: [String: String] = [
            "user-agent": "Mozilla/5.0",
            "origin": NiconicoMaster.origin,
            "referer": "\(NiconicoMaster.origin)/watch/\(programID)",
            "cookie": cookieHeader,
        ]
        return variants.map { variant in
            PlayStream(url: variant.url, quality: variant.label, line: "主线路", headers: headers)
        }
#else
        _ = watch
        throw LiveSiteError.notImplemented
#endif
    }

    // No danmaku: the protocol default yields an empty stream.
}
