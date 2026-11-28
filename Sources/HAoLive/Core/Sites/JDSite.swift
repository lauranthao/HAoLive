// JDSite.swift
// HAo Live — 京东直播 (jdlive) adapter (anonymous, no login).
// Endpoints (per the Pure Live reference; list verified live from
// this VM 2026-11-28, detail NOT verified — see note below):
//   list    GET api.m.jd.com/api?appid=h5-live&functionId=
//           liveListWithTabToM&v={ms}&body={"tabId":1,
//           "currentCount":"{count}","page":{page},"timestamp":{ms}}
//           with iPhone UA + Origin/Referer https://lives.jd.com
//           (without those headers the API answers 403
//           "cross-origin request ... is not allowed"). Verified:
//           200, code "0", 37 rows, 30 with templateType==1,
//           currentCount 37. Only templateType==1 rows are rooms;
//           data: {liveId (== id), authorId, userName, title,
//           userPic, indexImage, pv, status (1 = live)}.
//   search  No server search — filter the directory snapshot by
//           liveId / authorId / nick / title (local, per page).
//   detail  GET api.m.jd.com/api?appid=h5-live&functionId=
//           getImmediatePlayToM&t={ms}&body={"liveId":{id}} ->
//           {code: "0", subCode: "0", data: {liveId, status,
//           secret (1 = app-only, unplayable), h5VideoUrl (.m3u8),
//           videoUrl (.flv)}}. The HLS playlist is fetched once and
//           validated (#EXTM3U, child refs on the same host under
//           /live/ with the same stream stem). Only one tier: HLS
//           "原画". ⚠️ VM 2026-11-28: getImmediatePlayToM timed out
//           twice (curl 30s, python 20s) while the list endpoint
//           answers fine — needs a domestic real-device check.
// Danmaku: NOT implemented — the reference chat auth AES-encrypts
// its request with a hardcoded secret key; copying that key would
// break the no-copied-keys rule, so danmakuStream stays the
// default empty implementation.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class JDSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .jdlive
    private let http = HTTPClient.shared

    private static let apiBase = "https://api.m.jd.com/api"
    private static let webBase = "https://lives.jd.com"
    private static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    private static let pageSize = 30

    private static var headers: [String: String] {
        ["User-Agent": iPhoneUA, "Origin": webBase, "Referer": "\(webBase)/"]
    }

    private static var mediaHeaders: [String: String] {
        ["User-Agent": iPhoneUA, "Origin": webBase, "Referer": "\(webBase)/"]
    }

    /// Rooms seen in directory snapshots, so roomDetail can fill in
    /// the title / anchor the detail endpoint does not return.
    private var knownRooms: [String: LiveRoom] = [:]

    // MARK: - Categories

    /// No category tree — a single featured directory.
    func categories() async throws -> [LiveCategory] {
        []
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await directoryPage(page: 1).rooms
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await directoryPage(page: page).rooms
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await recommendRooms()
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await recommendRooms(page: page)
    }

    private struct DirectoryPage {
        let rooms: [LiveRoom]
        let nextCount: Int
        let hasMore: Bool
    }

    /// Walk the currentCount chain from page 1 to `page` (stateless;
    /// one timestamp per walk, as the reference does per sequence).
    private func directoryPage(page: Int) async throws -> DirectoryPage {
        guard page >= 1, page <= 50 else { return DirectoryPage(rooms: [], nextCount: 0, hasMore: false) }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        var currentCount = 0
        var result = DirectoryPage(rooms: [], nextCount: 0, hasMore: false)
        for current in 1...page {
            result = try await directory(page: current, currentCount: currentCount, timestamp: timestamp)
            guard result.hasMore else { break }
            currentCount = result.nextCount
        }
        return result
    }

    private func directory(page: Int, currentCount: Int, timestamp: Int) async throws -> DirectoryPage {
        let body = "{\"tabId\":1,\"currentCount\":\"\(currentCount)\",\"page\":\(page),\"timestamp\":\(timestamp)}"
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let json = try await http.getJSON(Self.urlWithQuery(Self.apiBase, [
            ("appid", "h5-live"),
            ("functionId", "liveListWithTabToM"),
            ("v", "\(millis)"),
            ("body", body),
        ]), headers: Self.headers)
        let data = try Self.responseData(json)
        var seen = Set<String>()
        var rooms: [LiveRoom] = []
        for card in data["list"].arrayValue {
            guard card["templateType"].intValue == 1 else { continue }
            guard let room = Self.room(fromListItem: card["data"]),
                  seen.insert(room.roomID).inserted else { continue }
            rooms.append(room)
            knownRooms[room.roomID] = room
        }
        guard let nextCount = data["currentCount"].intValue else {
            throw LiveSiteError.invalidResponse
        }
        return DirectoryPage(rooms: rooms, nextCount: nextCount, hasMore: rooms.count >= Self.pageSize)
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

    /// Local filter over one directory page (no server search).
    /// A bare live id goes straight to detail.
    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, page >= 1 else { return [] }
        if Self.validLiveID(query) != nil, page == 1 {
            if let detail = try? await roomDetail(roomID: query) {
                return [detail]
            }
            return []
        }
        let needle = query.lowercased()
        let pageRooms = try await directoryPage(page: page).rooms
        return pageRooms.filter { room in
            room.roomID.contains(needle)
                || room.anchorName.lowercased().contains(needle)
                || room.title.lowercased().contains(needle)
        }
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let liveID = Self.validLiveID(roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let data = try await fetchRoomData(liveID)
        return Self.room(fromDetailData: data, liveID: liveID, known: knownRooms[liveID])
    }

    /// The getImmediatePlayToM payload (detail + media fields).
    private func fetchRoomData(_ liveID: String) async throws -> JSONValue {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let body = "{\"liveId\":\"\(liveID)\"}"
        let json = try await http.getJSON(Self.urlWithQuery(Self.apiBase, [
            ("appid", "h5-live"),
            ("functionId", "getImmediatePlayToM"),
            ("t", "\(millis)"),
            ("body", body),
        ]), headers: Self.headers)
        let data = try Self.responseData(json)
        guard data["liveId"].stringValue == liveID else {
            throw LiveSiteError.roomNotFound(liveID)
        }
        return data
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let liveID = Self.validLiveID(room.roomID) else { return [] }
        let data = try await fetchRoomData(liveID)
        guard Self.state(of: data) == .live, !Self.isAppOnly(data) else { return [] }
        guard let hlsString = data["h5VideoUrl"].stringValue,
              let hlsURL = Self.validMediaURL(hlsString) else { return [] }
        // Validate the playlist once before handing it to the player.
        let playlistData = try await http.get(hlsString, headers: Self.mediaHeaders(for: liveID))
        guard let playlist = String(data: playlistData, encoding: .utf8),
              Self.isValidPlaylist(playlist, expected: hlsURL) else { return [] }
        return [PlayStream(
            url: hlsURL,
            quality: "原画",
            line: "主线路",
            headers: Self.mediaHeaders(for: liveID)
        )]
    }

    // MARK: - Pure parsers

    enum RoomState {
        case live, preview, offline, replay, paused, unknown
    }

    /// Live ids are 5–18 digits, first digit non-zero.
    static func validLiveID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 5, value.count <= 18,
              value.first.map({ $0 != "0" }) == true,
              value.allSatisfy({ $0.isNumber }) else { return nil }
        return value
    }

    /// code "0" + subCode "0" (both arrive as strings); data object.
    static func responseData(_ json: JSONValue) throws -> JSONValue {
        guard json["code"].stringValue == "0" else { throw LiveSiteError.invalidResponse }
        guard json["subCode"].stringValue == "0" else { throw LiveSiteError.invalidResponse }
        let data = json["data"]
        guard !data.isNull else { throw LiveSiteError.invalidResponse }
        return data
    }

    static func state(of data: JSONValue) -> RoomState {
        switch data["status"].intValue {
        case 1: return .live
        case 0: return .preview
        case 2: return .offline
        case 3: return .replay
        case 10, 11: return .paused
        default: return .unknown
        }
    }

    /// secret == 1 means app-only (needs the JD app): unplayable.
    static func isAppOnly(_ data: JSONValue) -> Bool {
        data["secret"].intValue == 1
    }

    /// Pure parser for a directory card (templateType == 1). The
    /// card's data.id must equal its liveId; only live rows are kept
    /// by the caller (status == 1).
    static func room(fromListItem item: JSONValue) -> LiveRoom? {
        guard let liveID = validLiveID(item["liveId"].stringValue ?? ""),
              item["id"].stringValue == liveID else { return nil }
        guard item["status"].intValue == 1 else { return nil }
        let nick = item["userName"].stringValue ?? ""
        return LiveRoom(
            id: "jdlive-\(liveID)",
            platform: .jdlive,
            roomID: liveID,
            title: HaoText.firstNonEmpty(item["title"].stringValue, nick.isEmpty ? nil : nick) ?? "京东直播",
            anchorName: nick.isEmpty ? "京东直播" : nick,
            anchorAvatarURL: Self.imageURL(item["userPic"].stringValue),
            coverURL: Self.imageURL(item["indexImage"].stringValue),
            categoryName: nil,
            viewerCount: item["pv"].intValue ?? 0,
            isLive: true
        )
    }

    /// Pure parser for the detail payload. The detail endpoint
    /// returns no title / anchor — those come from the directory
    /// snapshot when available.
    static func room(fromDetailData data: JSONValue, liveID: String, known: LiveRoom?) -> LiveRoom {
        let isLive = state(of: data) == .live
        return LiveRoom(
            id: "jdlive-\(liveID)",
            platform: .jdlive,
            roomID: liveID,
            title: known?.title ?? "京东直播",
            anchorName: known?.anchorName ?? "京东直播",
            anchorAvatarURL: known?.anchorAvatarURL,
            coverURL: known?.coverURL,
            categoryName: nil,
            viewerCount: known?.viewerCount ?? 0,
            isLive: isLive && !isAppOnly(data)
        )
    }

    /// HLS URL kept verbatim when valid: https, *.jdcloud.com host,
    /// /live/ path, .m3u8 suffix.
    static func validMediaURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(),
              host == "jdcloud.com" || host.hasSuffix(".jdcloud.com"),
              url.path.hasPrefix("/live/"),
              url.path.lowercased().hasSuffix(".m3u8") else { return nil }
        return url
    }

    static func mediaHeaders(for liveID: String) -> [String: String] {
        ["User-Agent": iPhoneUA, "Origin": webBase, "Referer": "\(webBase)/#/\(liveID)"]
    }

    /// Playlist check: must be an #EXTM3U document whose media
    /// references (bare lines and URI="..." attributes) resolve to
    /// the same host, under /live/, with the same stream stem.
    static func isValidPlaylist(_ source: String, expected: URL) -> Bool {
        guard source.count <= 1_048_576,
              source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return false }
        let stem = Self.streamStem(of: expected)
        var references = 0
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                for uri in Self.quotedURIs(in: line) {
                    guard Self.isValidChild(uri, expected: expected, stem: stem) else { return false }
                    references += 1
                }
                continue
            }
            guard Self.isValidChild(line, expected: expected, stem: stem) else { return false }
            references += 1
            guard references <= 1000 else { return false }
        }
        return references >= 1
    }

    static func quotedURIs(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[r])
        }
    }

    static func isValidChild(_ raw: String, expected: URL, stem: String) -> Bool {
        guard let child = URL(string: raw, relativeTo: expected)?.absoluteURL,
              child.scheme == "https", child.user == nil, child.password == nil, child.fragment == nil,
              child.host?.lowercased() == expected.host?.lowercased(),
              child.path.hasPrefix("/live/"),
              let last = child.pathComponents.last, last.hasPrefix(stem) else { return false }
        return true
    }

    /// Filename minus the .m3u8 / .flv extension.
    static func streamStem(of url: URL) -> String {
        let name = url.pathComponents.last ?? ""
        if name.lowercased().hasSuffix(".m3u8") { return String(name.dropLast(5)) }
        if name.lowercased().hasSuffix(".flv") { return String(name.dropLast(4)) }
        return name
    }

    /// Build a URL with percent-encoded query items.
    static func urlWithQuery(_ base: String, _ params: [(String, String)]) -> String {
        guard var components = URLComponents(string: base) else { return base }
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.string ?? base
    }
}
