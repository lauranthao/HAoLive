// ChzzkSite.swift
// HAo Live — CHZZK (Naver) adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   list    GET api.chzzk.naver.com/service/v1/lives?size=3
//           -> {code: 200, content: {data: [{liveId, liveTitle,
//              liveImageUrl, liveCategoryValue, concurrentUserCount,
//              adult, channel: {channelId (32 hex), channelName,
//              channelImageUrl}}], page: {next: {concurrentUserCount,
//              liveId}}}} (cursor paging: next is exclusive (ref 20-6);
//              the boundary row is dropped as a guard)
//   search  GET api.chzzk.naver.com/service/v1/search/channels
//           ?keyword=&offset=&size= -> content.data[] each
//           {channel: {...}} (channel cards, may be offline)
//   channel GET api.chzzk.naver.com/service/v1/channels/{id}
//   detail  GET api.chzzk.naver.com/service/v3.1/channels/{id}
//           /live-detail -> content {status OPEN/CLOSE, liveId,
//           liveTitle, liveImageUrl, liveCategoryValue,
//           concurrentUserCount, cvExposure, adult, krOnlyViewing,
//           timeMachineActive, livePlaybackJson (a JSON *string*),
//           chatChannelId}; livePlaybackJson.media[] holds the HLS
//           master URLs (mediaId HLS / LLHLS, protocol HLS).
//   play    fetch each media.url master m3u8 (together in the ref;
//           here one after another), parse its #EXT-X-STREAM-INF
//           variants into qualities "{height}p{60?} · HLS", one line
//           per media (HLS / LLHLS) (verified: 144p/360p/480p/720p60/
//           1080p60 from one master). adult && media empty =
//           adult-verified room, skipped (no playable URL);
//           krOnlyViewing = region restricted, likewise unplayable.
//   Headers: API = desktop Chrome UA + Origin/Referer
//           https://chzzk.naver.com; media = same UA + Referer, no Origin.
// Danmaku: Naver chat WebSocket — see ChzzkDanmaku.swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ChzzkSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .chzzk
    private let http = HTTPClient.shared

    private static let apiBase = "https://api.chzzk.naver.com"
    private static let webBase = "https://chzzk.naver.com"
    private static let pageSize = 30
    private static let searchPageSize = 20

    // Ref headers (chzzk_api.dart ChzzkApi.headers): desktop Chrome UA
    // + Origin/Referer. HTTPClient would otherwise send its macOS UA.
    private static var headers: [String: String] {
        ["User-Agent": PlaybackHeaders.desktopUA, "Origin": webBase, "Referer": "\(webBase)/"]
    }

    /// One directory cursor: the server cursor is exclusive (ref 20-6)
    /// (concurrentUserCount + liveId of the last row seen).
    private struct Cursor {
        let viewers: Int
        let liveId: Int
    }

    private struct DirectoryPage {
        let rooms: [LiveRoom]
        let next: Cursor?
    }

    // MARK: - Categories

    /// No category tree on CHZZK — only one "hot" directory.
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

    /// Walk the cursor chain from page 1 to `page` (stateless).
    private func directoryPage(page: Int) async throws -> DirectoryPage {
        guard page >= 1, page <= 20 else { return DirectoryPage(rooms: [], next: nil) }
        var cursor: Cursor?
        var result = DirectoryPage(rooms: [], next: nil)
        for _ in 1...page {
            result = try await directory(cursor: cursor)
            guard let next = result.next else { break }
            cursor = next
        }
        return result
    }

    private func directory(cursor: Cursor?) async throws -> DirectoryPage {
        var params: [(String, String)] = [("size", "\(Self.pageSize)")]
        if let cursor {
            params.append(("concurrentUserCount", "\(cursor.viewers)"))
            params.append(("liveId", "\(cursor.liveId)"))
        }
        let json = try await http.getJSON(Self.urlWithQuery("\(Self.apiBase)/service/v1/lives", params), headers: Self.headers)
        guard json["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let content = json["content"]
        var rows = content["data"].arrayValue
        // The server cursor is exclusive (ref 20-6); drop a repeated
        // boundary row if the server sends one anyway.
        if let cursor {
            rows.removeAll { $0["liveId"].intValue == cursor.liveId }
        }
        let rooms = rows.map(Self.room(fromListItem:))
        var next: Cursor?
        let nextObj = content["page"]["next"]
        if !nextObj.isNull,
           let viewers = nextObj["concurrentUserCount"].intValue,
           let liveId = nextObj["liveId"].intValue, liveId > 0 {
            next = Cursor(viewers: viewers, liveId: liveId)
        }
        return DirectoryPage(rooms: rooms, next: next)
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

    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        // Ref searchKeyword: trim, cut to 100 characters.
        let query = String(keyword.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !query.isEmpty, page >= 1 else { return [] }
        let offset = (page - 1) * Self.searchPageSize
        let json = try await http.getJSON(Self.urlWithQuery("\(Self.apiBase)/service/v1/search/channels", [
            ("keyword", query),
            ("offset", "\(offset)"),
            ("size", "\(Self.searchPageSize)"),
        ]), headers: Self.headers)
        guard json["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        return json["content"]["data"].arrayValue.map { item in
            Self.room(fromChannel: item["channel"])
        }
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let channelID = Self.validChannelID(roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let channel = try await fetchChannel(channelID)
        guard let live = try await fetchLiveDetail(channelID) else {
            // No live-detail at all: channel card, offline.
            return Self.room(fromChannel: channel, forceOffline: true)
        }
        return Self.room(fromLiveDetail: live, channel: channel)
    }

    /// The channel object (/service/v1/channels/{id}).
    private func fetchChannel(_ channelID: String) async throws -> JSONValue {
        let json = try await http.getJSON("\(Self.apiBase)/service/v1/channels/\(channelID)", headers: Self.headers)
        // Ref channel(): a 200 with a null / mismatched channelId is
        // NotFound (unknown ids answer 200 with channelId null).
        guard json["code"].intValue == 200, !json["content"].isNull,
              json["content"]["channelId"].stringValue == channelID else {
            throw LiveSiteError.roomNotFound(channelID)
        }
        return json["content"]
    }

    /// The v3.1 live-detail object. Nil when the channel has no
    /// live-detail content (never been live / gone).
    private func fetchLiveDetail(_ channelID: String) async throws -> JSONValue? {
        let json = try await http.getJSON("\(Self.apiBase)/service/v3.1/channels/\(channelID)/live-detail", headers: Self.headers)
        guard json["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let content = json["content"]
        return content.isNull ? nil : content
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let channelID = Self.validChannelID(room.roomID) else { return [] }
        // Ref: a failed detail fetch is an error, never an offline room
        // (chzzk_site.dart throws NetworkFailure / ApiChanged). Only a
        // null content (never been live) or a non-OPEN status yields [].
        guard let live = try await fetchLiveDetail(channelID) else { return [] }
        guard Self.isLiveStatus(live["status"].stringValue) else { return [] }
        let detail = live
        let media = Self.playbackMedia(fromLivePlaybackJSON: detail["livePlaybackJson"].stringValue ?? "")
        // Adult-verified rooms and region-restricted rooms carry no media.
        guard !media.isEmpty else { return [] }
        // Ref mediaHeaders (chzzk_api.dart): desktop Chrome UA + Referer,
        // no Origin — for the master fetches and the stream lines alike.
        let headers = ["User-Agent": PlaybackHeaders.desktopUA, "Referer": "\(Self.webBase)/"]
        var builders: [String: QualityBuilder] = [:]
        var firstMasterError: (any Error)?
        for item in media {
            guard let masterURL = URL(string: item.url) else { continue }
            let text: String
            do {
                let textData = try await http.get(item.url, headers: headers)
                guard let decoded = String(data: textData, encoding: .utf8) else { continue }
                text = decoded
            } catch {
                // Ref _fetchQualities: one failed master only loses its
                // lines; when every master fails, the first error is thrown.
                if firstMasterError == nil { firstMasterError = error }
                continue
            }
            for variant in Self.parseMasterPlaylist(text, baseURL: masterURL) {
                // Ref qualities(): quality "<height>p[60] · HLS", one line
                // per media (lineId HLS / LLHLS), ranked by height, then
                // by the bandwidth of its first variant, best first.
                let quality = "\(variant.height)p\(variant.fps >= 50 ? "60" : "") · HLS"
                let rank = variant.height * 10_000_000 + variant.bandwidth
                let key = "\(quality)|\(item.id)"
                if builders[key] == nil {
                    builders[key] = QualityBuilder(quality: quality, rank: rank, line: item.id)
                }
                if !builders[key]!.urls.contains(variant.url) {
                    builders[key]!.urls.append(variant.url)
                }
            }
        }
        let streams = Self.streams(fromBuilders: builders, headers: headers)
        if streams.isEmpty, let error = firstMasterError { throw error }
        return streams
    }

    /// Quality -> streams, best first. Pure builder, testable
    /// without the network.
    static func streams(fromBuilders builders: [String: QualityBuilder], headers: [String: String]) -> [PlayStream] {
        let sorted = builders.values.sorted { $0.rank > $1.rank }
        var streams: [PlayStream] = []
        for builder in sorted {
            for url in builder.urls {
                streams.append(PlayStream(url: url, quality: builder.quality, line: builder.line, headers: headers))
            }
        }
        return streams
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return ChzzkDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Pure parsers

    /// One quality's variant URLs, in master order. `quality` is the
    /// display name ("1080p60 · HLS"); `line` is the media id
    /// ("HLS" / "LLHLS"), one builder per media.
    struct QualityBuilder {
        var quality: String = ""
        let rank: Int
        let line: String
        var urls: [URL] = []
    }

    /// A channel id is a 32-char lowercase hex string.
    static func validChannelID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count == 32, id.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { return nil }
        return id
    }

    static func isLiveStatus(_ status: String?) -> Bool {
        status == "OPEN"
    }

    /// Cover URL: the {type} placeholder is the thumbnail size.
    static func coverURL(primary: String?, fallback: String?) -> URL? {
        for raw in [primary, fallback] {
            guard var value = raw, !value.isEmpty else { continue }
            value = value.replacingOccurrences(of: "{type}", with: "480")
            if let url = Self.imageURL(value) { return url }
        }
        return nil
    }

    static func viewers(of data: JSONValue) -> Int {
        // concurrentUserCount is only shown when cvExposure is true.
        guard data["cvExposure"].boolValue == true else { return 0 }
        return data["concurrentUserCount"].intValue ?? 0
    }

    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let channel = item["channel"]
        return LiveRoom(
            id: "chzzk-\(channel["channelId"].stringValue ?? "")",
            platform: .chzzk,
            roomID: channel["channelId"].stringValue ?? "",
            title: item["liveTitle"].stringValue ?? "",
            anchorName: channel["channelName"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(channel["channelImageUrl"].stringValue),
            coverURL: coverURL(primary: item["liveImageUrl"].stringValue, fallback: item["defaultThumbnailImageUrl"].stringValue),
            categoryName: item["liveCategoryValue"].stringValue ?? item["liveCategory"].stringValue,
            viewerCount: item["concurrentUserCount"].intValue ?? 0,
            isLive: true
        )
    }

    static func room(fromChannel channel: JSONValue, forceOffline: Bool = false) -> LiveRoom {
        let id = channel["channelId"].stringValue ?? ""
        return LiveRoom(
            id: "chzzk-\(id)",
            platform: .chzzk,
            roomID: id,
            title: channel["channelName"].stringValue ?? "",
            anchorName: channel["channelName"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(channel["channelImageUrl"].stringValue),
            coverURL: Self.imageURL(channel["channelImageUrl"].stringValue),
            categoryName: nil,
            viewerCount: 0,
            isLive: !forceOffline && (channel["openLive"].boolValue == true)
        )
    }

    static func room(fromLiveDetail detail: JSONValue, channel: JSONValue) -> LiveRoom {
        let id = channel["channelId"].stringValue ?? ""
        let isLive = isLiveStatus(detail["status"].stringValue)
        return LiveRoom(
            id: "chzzk-\(id)",
            platform: .chzzk,
            roomID: id,
            title: HaoText.firstNonEmpty(detail["liveTitle"].stringValue, channel["channelName"].stringValue) ?? "",
            anchorName: channel["channelName"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(channel["channelImageUrl"].stringValue),
            coverURL: coverURL(primary: detail["liveImageUrl"].stringValue, fallback: detail["defaultThumbnailImageUrl"].stringValue),
            categoryName: detail["liveCategoryValue"].stringValue ?? detail["liveCategory"].stringValue,
            viewerCount: viewers(of: detail),
            isLive: isLive
        )
    }

    /// One HLS media entry from livePlaybackJson (a JSON string).
    struct MediaEntry {
        let id: String
        let url: String
        var lowLatency: Bool { id == "LLHLS" }
    }

    /// Parse livePlaybackJson: keep HLS media only (mediaId HLS /
    /// LLHLS), deduped by URL.
    static func playbackMedia(fromLivePlaybackJSON raw: String) -> [MediaEntry] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let json = JSONValue.parse(data) else { return [] }
        var seen = Set<String>()
        var out: [MediaEntry] = []
        for item in json["media"].arrayValue {
            guard item["protocol"].stringValue == "HLS" else { continue }
            let mediaID = item["mediaId"].stringValue ?? ""
            guard mediaID == "HLS" || mediaID == "LLHLS" else { continue }
            guard let url = item["path"].stringValue, !url.isEmpty, seen.insert(url).inserted else { continue }
            out.append(MediaEntry(id: mediaID, url: url))
        }
        return out
    }

    /// One variant of an HLS master playlist.
    struct MasterVariant {
        let height: Int
        let fps: Double
        let bandwidth: Int
        let url: URL
    }

    /// Parse #EXT-X-STREAM-INF variants. Relative URIs resolve
    /// against the master URL. Testable without the network.
    static func parseMasterPlaylist(_ text: String, baseURL: URL) -> [MasterVariant] {
        let lines = text.components(separatedBy: .newlines)
        var variants: [MasterVariant] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { i += 1; continue }
            let attrs = Self.parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            var uriLine: String?
            var j = i + 1
            while j < lines.count {
                let next = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                if !next.isEmpty {
                    uriLine = next.hasPrefix("#") ? nil : next
                    break
                }
                j += 1
            }
            if let uriLine, !uriLine.hasPrefix("#"),
               let resolution = attrs["RESOLUTION"],
               let height = Int(resolution.split(separator: "x").last.map(String.init) ?? ""),
               height > 0,
               let bandwidth = Int(attrs["BANDWIDTH"] ?? ""), bandwidth > 0,
               let url = URL(string: uriLine, relativeTo: baseURL)?.absoluteURL {
                let fps = Double(attrs["FRAME-RATE"] ?? "") ?? 0
                variants.append(MasterVariant(height: height, fps: fps, bandwidth: bandwidth, url: url))
            }
            i = j + 1
        }
        return variants
    }

    /// Split a comma-separated attribute list, keeping quoted values
    /// (CODECS="avc1.640028,mp4a.40.2") intact.
    static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ",", !inQuotes { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            var value = String(kv[1]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// Build a URL with percent-encoded query items.
    static func urlWithQuery(_ base: String, _ params: [(String, String)]) -> String {
        guard var components = URLComponents(string: base) else { return base }
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.string ?? base
    }
}
