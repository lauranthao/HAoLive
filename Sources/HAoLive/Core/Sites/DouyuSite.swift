// DouyuSite.swift
// HAo Live — real Douyu adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-26:
//   categories  GET open.douyucdn.cn/api/RoomApi/game
//   live list   GET open.douyucdn.cn/api/RoomApi/live?limit=N
//   category    GET open.douyucdn.cn/api/RoomApi/live/{cate_id}?offset=&limit=
//   room detail GET open.douyucdn.cn/api/RoomApi/room/{room_id}
// Play URLs (NOT verifiable from this VM — Douyu's web anti-bot
// answers error -9 "时间戳错误" to every getH5Play call from here,
// and the room page itself is a 36KB JS shell with no room data):
//   POST www.douyu.com/lapi/live/getH5Play/{room_id}
//   body rate={0..3}, Cookie dy_did={random 32-hex},
//   Referer https://www.douyu.com/{room_id}
//   -> {error: 0, data: {rtmp_url, rtmp_live, hls_url}}
//   rate map (documented): 0 原画, 1 流畅, 2 高清, 3 超清.
//   Only hls_url is offered: AVPlayer cannot play RTMP.
//   This flow is the same request a real browser makes; it needs
//   validation on a China-network device before it counts as working.
// Danmaku: raw TCP to openbarrage.douyutv.com:8601 (STT protocol);
// the VM's egress proxy blocks raw TCP, so the channel is verified
// by fixtures only — it runs on the user's phone, not through here.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DouyuSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .douyu
    private let http = HTTPClient.shared

    private static let openBase = "https://open.douyucdn.cn/api/RoomApi"
    private static let webBase = "https://www.douyu.com"

    /// Documented rate -> quality map for getH5Play.
    private static let rateQualities: [(rate: Int, quality: String)] = [
        (0, "原画"), (3, "超清"), (2, "高清"), (1, "流畅"),
    ]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.openBase)/game")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return Self.categories(fromGameList: json["data"])
    }

    /// Pure parser for the game list. Testable without the network.
    static func categories(fromGameList data: JSONValue) -> [LiveCategory] {
        data.arrayValue.compactMap { item in
            guard let id = item["cate_id"].stringValue,
                  let name = item["game_name"].stringValue, !name.isEmpty else { return nil }
            return LiveCategory(id: "douyu-\(id)", platform: .douyu, name: name, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        let json = try await http.getJSON("\(Self.openBase)/live?limit=30")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"].arrayValue.map(Self.room(fromListItem:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        let cateID = category.id.dropFirst("douyu-".count)
        let json = try await http.getJSON("\(Self.openBase)/live/\(cateID)?offset=0&limit=30")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"].arrayValue.map(Self.room(fromListItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    /// Douyu's web search API. The endpoint answers from a real
    /// browser; from this VM it returns a "提示信息" bot page, so the
    /// response shape is parsed defensively and the call is marked
    /// unverified until a device confirms it.
    private func search(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(Self.webBase)/api/search/api/searchRoom?kw=\(encoded)"
        let data = try await http.get(url, headers: ["Referer": "\(Self.webBase)/"])
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        let list = json["data"]["list"].arrayValue
        return list.map(Self.room(fromListItem:))
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let json = try await http.getJSON("\(Self.openBase)/room/\(roomID)")
        guard json["error"].intValue == 0 else { throw LiveSiteError.roomNotFound(roomID) }
        guard let room = Self.room(fromDetail: json["data"]) else { throw LiveSiteError.roomNotFound(roomID) }
        return room
    }

    /// Pure parser for a room detail response. Testable without the network.
    static func room(fromDetail data: JSONValue) -> LiveRoom? {
        guard let id = data["room_id"].stringValue else { return nil }
        return LiveRoom(
            id: "douyu-\(id)",
            platform: .douyu,
            roomID: id,
            title: data["room_name"].stringValue ?? "",
            anchorName: data["owner_name"].stringValue ?? "",
            anchorAvatarURL: URL(string: data["avatar"].stringValue ?? ""),
            coverURL: URL(string: data["room_thumb"].stringValue ?? ""),
            categoryName: data["cate_name"].stringValue,
            viewerCount: data["online"].intValue ?? data["hn"].intValue ?? 0,
            isLive: data["room_status"].stringValue == "1"
        )
    }

    // MARK: - Play URLs

    func playURLs(roomID: String) async throws -> [PlayStream] {
        // One request per quality tier, in parallel; tiers the server
        // refuses are skipped, never faked.
        let did = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var streams: [PlayStream] = []
        await withTaskGroup(of: PlayStream?.self) { group in
            for (rate, quality) in Self.rateQualities {
                group.addTask {
                    let headers = [
                        "Referer": "\(Self.webBase)/\(roomID)",
                        "Cookie": "dy_did=\(did)",
                    ]
                    guard let json = try? await self.http.postFormJSON(
                        "\(Self.webBase)/lapi/live/getH5Play/\(roomID)",
                        fields: ["rate": String(rate)],
                        headers: headers
                    ), let stream = Self.stream(fromPlayResponse: json, quality: quality) else { return nil }
                    return stream
                }
            }
            for await stream in group {
                if let stream { streams.append(stream) }
            }
        }
        // Best quality first (原画, 超清, 高清, 流畅).
        let order = Self.rateQualities.map(\.quality)
        return streams.sorted { order.firstIndex(of: $0.quality) ?? 99 < order.firstIndex(of: $1.quality) ?? 99 }
    }

    /// Pure parser for one getH5Play response. Testable without the network.
    static func stream(fromPlayResponse json: JSONValue, quality: String) -> PlayStream? {
        guard json["error"].intValue == 0,
              let hls = json["data"]["hls_url"].stringValue,
              !hls.isEmpty, let url = URL(string: hls) else { return nil }
        return PlayStream(url: url, quality: quality, line: "主线路")
    }

    // MARK: - Danmaku

    func sampleDanmaku(roomID: String) async -> [DanmakuItem] {
        [] // real channel below; never show fake lines as live danmaku
    }

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        #if canImport(Network)
        return DouyuDanmaku.stream(roomID: roomID)
        #else
        return AsyncStream { $0.finish() }
        #endif
    }

    // MARK: - Mapping helpers

    /// Pure parser for a list item (recommend / category / search).
    /// Testable without the network.
    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let roomID = item["room_id"].stringValue ?? ""
        return LiveRoom(
            id: "douyu-\(roomID)",
            platform: .douyu,
            roomID: roomID,
            title: item["room_name"].stringValue ?? "",
            anchorName: item["nickname"].stringValue ?? item["owner_name"].stringValue ?? "",
            anchorAvatarURL: URL(string: item["avatar"].stringValue ?? ""),
            coverURL: URL(string: HaoText.firstNonEmpty(item["room_src"].stringValue, item["room_thumb"].stringValue) ?? ""),
            categoryName: item["cate_name"].stringValue,
            viewerCount: item["online"].intValue ?? item["hn"].intValue ?? 0,
            isLive: true
        )
    }
}
