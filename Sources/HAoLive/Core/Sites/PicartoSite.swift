// PicartoSite.swift
// HAo Live — real Picarto adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   categories GET ptvintern.picarto.tv/api/languages-categories
//              -> {categories: [{id, label, online_channels, …}]}
//              (25 categories; "Adult" id 22 is excluded here)
//   list       GET ptvintern.picarto.tv/api/explore?first=3&page=1
//              &filter_params[adult]=false
//              &order_by[field]=viewers&order_by[order]=DESC
//              &type=stream -> {current_page, last_page, total,
//              data: [{name, id, online, viewers, title, avatar,
//              image_thumbnail, categories: [{id, name}],
//              adult}]} (3 rooms)
//   category   same explore + filter_params[categories]={id}: true
//              (per Pure Live; NOT separately verified from VM)
//   search     GET ptvintern.picarto.tv/api/search?first=3&page=1
//              &q=Silver&type=searchProfiles&tag_search=false
//              -> {searchProfiles: {data: [{id, name, online,
//              avatar, follower_count}]}} (verified: 3 profiles,
//              offline ones included — searchRooms keeps live
//              only, searchAnchors keeps all)
//   detail     GET ptvintern.picarto.tv/api/channel/detail/{name}
//              -> {channel: {name, id, online, private, title,
//              viewers, avatar, image_thumbnail},
//              getLoadBalancerUrl: {origin: "edge1-us-miami"},
//              getMultiStreams: {streams: [{channelId,
//              stream_name, thumbnail_image}]}} (verified for
//              SilverTsuki: stream_name "golive+SilverTsuki")
//   play       master = https://{origin}.picarto.tv/stream/hls/
//              {stream_name}/index.m3u8 — fetched (verified):
//              #EXTM3U + one #EXT-X-STREAM-INF variant
//              (BANDWIDTH=425392, RESOLUTION=1280x720) with a
//              relative URL (0_1/index.m3u8), resolved against the
//              master. Private rooms (private=true) are skipped.
// Danmaku: WS (see PicartoDanmaku.swift) — a JWT from the
// ptvapi GraphQL endpoint, then wss://chat.picarto.tv/chat/
// token={jwt}. The token endpoint was verified live (a JWT was
// returned for SilverTsuki); the socket itself was not.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PicartoSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .picarto
    private let http = HTTPClient.shared

    private static let apiBase = "https://ptvintern.picarto.tv"
    private static let pageSize = 30

    /// Playback headers (Pure Live's PicartoApi.playHeaders).
    private static let playHeaders: [String: String] = [
        "user-agent": PlaybackHeaders.desktopUA,
        "origin": "https://picarto.tv",
        "referer": "https://picarto.tv/",
    ]

    // MARK: - Categories

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.apiBase)/api/languages-categories", headers: Self.playHeaders)
        return Self.categories(fromJSON: json)
    }

    /// Pure parser for /api/languages-categories. The Adult
    /// category is excluded — its rooms are filtered out of the
    /// lists anyway, and it must not be offered as a browse entry.
    /// Testable without the network.
    static func categories(fromJSON json: JSONValue) -> [LiveCategory] {
        var out: [LiveCategory] = []
        var seen: Set<String> = []
        for item in json["categories"].arrayValue {
            guard let id = item["id"].intValue, id > 0,
                  let label = item["label"].stringValue, !label.isEmpty,
                  label.lowercased() != "adult" else { continue }
            let categoryID = "picarto-\(id)"
            guard seen.insert(categoryID).inserted else { continue }
            out.append(LiveCategory(id: categoryID, platform: .picarto, name: label, iconName: nil))
        }
        return out
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await explore(page: page, categoryID: nil)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard category.id.hasPrefix("picarto-"),
              let id = Int(category.id.dropFirst("picarto-".count)) else { return [] }
        return try await explore(page: page, categoryID: id)
    }

    /// GET /api/explore, optionally filtered to one category.
    /// Adult and offline rows are dropped.
    private func explore(page: Int, categoryID: Int?) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        var query = "first=\(Self.pageSize)&page=\(page)&filter_params[adult]=false&order_by[field]=viewers&order_by[order]=DESC&type=stream"
        if let categoryID {
            query += "&filter_params[languages]=&filter_params[categories]=\(categoryID): true"
        }
        let json = try await http.getJSON("\(Self.apiBase)/api/explore?\(query)", headers: Self.playHeaders)
        return json["data"].arrayValue.compactMap(Self.room(fromExploreItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        let anchors = try await searchProfiles(keyword: keyword, page: 1)
        return anchors.filter { $0.isLive }
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let anchors = try await searchProfiles(keyword: keyword, page: page)
        return anchors.filter { $0.isLive }
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchProfiles(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchProfiles(keyword: keyword, page: page)
    }

    private func searchProfiles(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, page >= 1 else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let json = try await http.getJSON(
            "\(Self.apiBase)/api/search?first=\(Self.pageSize)&page=\(page)&q=\(encoded)&type=searchProfiles&tag_search=false",
            headers: Self.playHeaders
        )
        return json["searchProfiles"]["data"].arrayValue.compactMap(Self.room(fromSearchProfile:))
    }

    // MARK: - Room detail

    /// Detail result: the room plus its HLS master URL (nil when
    /// the room is offline or private).
    struct Detail {
        let room: LiveRoom
        let master: URL?
    }

    func roomDetail(roomID: String) async throws -> LiveRoom {
        try await Self.detail(roomID: roomID).room
    }

    /// GET /api/channel/detail/{name}. Private rooms return
    /// isLive false and no master; the master URL rides on
    /// playDataJSON so playURLs can use it without re-fetching.
    static func detail(roomID: String) async throws -> Detail {
        let name = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LiveSiteError.roomNotFound(roomID) }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let json = try await HTTPClient.shared.getJSON("\(apiBase)/api/channel/detail/\(encoded)", headers: playHeaders)
        let channel = json["channel"]
        guard let room = room(fromDetailChannel: channel, expectedName: name) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        guard room.isLive else { return Detail(room: room, master: nil) }
        let origin = json["getLoadBalancerUrl"]["origin"].stringValue ?? ""
        guard !origin.isEmpty,
              origin.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let channelID = channel["id"].stringValue else {
            return Detail(room: room, master: nil)
        }
        var streamName: String?
        for stream in json["getMultiStreams"]["streams"].arrayValue {
            if stream["channelId"].stringValue == channelID {
                streamName = stream["stream_name"].stringValue
                break
            }
        }
        guard let streamName, !streamName.isEmpty,
              let master = URL(string: "https://\(origin).picarto.tv/stream/hls/\(streamName)/index.m3u8") else {
            return Detail(room: room, master: nil)
        }
        var roomWithMaster = room
        roomWithMaster.playDataJSON = JSONValue.object(["master": .string(master.absoluteString)]).jsonString
        return Detail(room: roomWithMaster, master: master)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let master: URL
        if let carried = room.playDataJSON,
           let data = carried.data(using: .utf8),
           let json = JSONValue.parse(data),
           let masterString = json["master"].stringValue,
           let carriedMaster = URL(string: masterString) {
            master = carriedMaster
        } else {
            guard let fetched = try await Self.detail(roomID: room.roomID).master else { return [] }
            master = fetched
        }
        let data = try await http.get(master.absoluteString, headers: Self.playHeaders)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Self.streams(fromMasterPlaylist: text, master: master)
    }

    /// Pure parser for a master playlist: one PlayStream per
    /// #EXT-X-STREAM-INF variant, best bandwidth first; a media
    /// playlist (segments, no variants) or a master with external
    /// audio yields a single "HLS Auto" stream on the master URL
    /// itself (never claim a tier that is not there).
    /// Testable without the network.
    static func streams(fromMasterPlaylist content: String, master: URL) -> [PlayStream] {
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { return [] }
        var variants: [(label: String, rank: Int, url: URL)] = []
        var hasExternalAudio = false
        var hasMediaSegments = false
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=AUDIO"), line.contains("URI=") {
                hasExternalAudio = true
            }
            if line.hasPrefix("#EXTINF:") { hasMediaSegments = true }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = Self.streamAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let attrs = pending else {
                if hasMediaSegments { continue }
                continue
            }
            pending = nil
            guard let url = URL(string: line, relativeTo: master)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { continue }
            let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
            guard bandwidth > 0 else { continue }
            let resolution = attrs["RESOLUTION"] ?? ""
            let size = resolution.split(separator: "x").compactMap { Int($0) }
            let fps = Double(attrs["FRAME-RATE"] ?? "") ?? 0
            let label: String
            if size.count == 2 {
                let fpsText = fps > 0 ? (fps == fps.rounded() ? " \(Int(fps))fps" : " \(fps)fps") : ""
                label = "\(size[1])p\(fpsText)"
            } else {
                label = String(format: "HLS %.1f Mbps", Double(bandwidth) / 1_000_000.0)
            }
            variants.append((label: label, rank: bandwidth, url: url))
        }
        if variants.isEmpty || hasExternalAudio {
            return [PlayStream(url: master, quality: "HLS Auto", line: "主线路", headers: playHeaders)]
        }
        variants.sort { $0.rank > $1.rank }
        var seen: Set<String> = []
        var streams: [PlayStream] = []
        for variant in variants {
            guard seen.insert(variant.url.absoluteString).inserted else { continue }
            streams.append(PlayStream(url: variant.url, quality: variant.label, line: "主线路", headers: playHeaders))
        }
        return streams
    }

    /// Attributes of an #EXT-X-STREAM-INF line: KEY=value pairs,
    /// values optionally double-quoted.
    static func streamAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var rest = text
        while !rest.isEmpty {
            guard let eq = rest.firstIndex(of: "=") else { break }
            let key = String(rest[..<eq]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[rest.index(after: eq)...])
            var value: String
            if rest.hasPrefix("\"") {
                rest = String(rest.dropFirst())
                if let end = rest.firstIndex(of: "\"") {
                    value = String(rest[..<end])
                    rest = String(rest[rest.index(after: end)...])
                } else {
                    value = rest
                    rest = ""
                }
            } else if let comma = rest.firstIndex(of: ",") {
                value = String(rest[..<comma])
                rest = String(rest[rest.index(after: comma)...])
            } else {
                value = rest
                rest = ""
            }
            if !key.isEmpty { out[key] = value }
            rest = rest.trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix(",") { rest = String(rest.dropFirst()) }
        }
        return out
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return PicartoDanmaku.stream(channelName: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Mapping helpers

    /// Pure parser for an explore row. Adult and offline rows are
    /// dropped (nil). Testable without the network.
    static func room(fromExploreItem item: JSONValue) -> LiveRoom? {
        guard let name = item["name"].stringValue, !name.isEmpty,
              item["adult"].boolValue != true,
              item["online"].boolValue == true else { return nil }
        var category: String?
        let names = item["categories"].arrayValue.compactMap { $0["name"].stringValue }.filter { !$0.isEmpty }
        if !names.isEmpty { category = names.joined(separator: " / ") }
        return LiveRoom(
            id: "picarto-\(name)",
            platform: .picarto,
            roomID: name,
            title: item["title"].stringValue ?? "",
            anchorName: name,
            anchorAvatarURL: Self.imageURL(item["avatar"].stringValue),
            coverURL: Self.imageURL(item["image_thumbnail"].stringValue),
            categoryName: category,
            viewerCount: item["viewers"].intValue ?? 0,
            isLive: true
        )
    }

    /// Pure parser for a searchProfiles row (an anchor; offline
    /// ones are kept, with isLive false).
    static func room(fromSearchProfile item: JSONValue) -> LiveRoom? {
        guard let name = item["name"].stringValue, !name.isEmpty else { return nil }
        let online = item["online"].boolValue == true
        return LiveRoom(
            id: "picarto-\(name)",
            platform: .picarto,
            roomID: name,
            title: "",
            anchorName: name,
            anchorAvatarURL: Self.imageURL(item["avatar"].stringValue),
            coverURL: nil,
            categoryName: nil,
            viewerCount: 0,
            isLive: online
        )
    }

    /// Pure parser for a channel/detail `channel` object. Returns
    /// nil when the name does not match. A private room is
    /// reported as not live.
    static func room(fromDetailChannel channel: JSONValue, expectedName: String) -> LiveRoom? {
        guard let name = channel["name"].stringValue, !name.isEmpty,
              name.lowercased() == expectedName.lowercased(),
              channel["online"].boolValue != nil else { return nil }
        let online = channel["online"].boolValue == true
        let isPrivate = channel["private"].boolValue == true
        var category: String?
        let names = channel["categories"].arrayValue.compactMap { $0["name"].stringValue }.filter { !$0.isEmpty }
        if !names.isEmpty { category = names.joined(separator: " / ") }
        return LiveRoom(
            id: "picarto-\(name)",
            platform: .picarto,
            roomID: name,
            title: channel["title"].stringValue ?? "",
            anchorName: name,
            anchorAvatarURL: Self.imageURL(channel["avatar"].stringValue),
            coverURL: Self.imageURL(channel["image_thumbnail"].stringValue),
            categoryName: category,
            viewerCount: channel["viewers"].intValue ?? 0,
            isLive: online && !isPrivate
        )
    }
}
