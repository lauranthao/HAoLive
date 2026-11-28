// WeiboSite.swift
// HAo Live — 微博直播 adapter (anonymous, no login).
//
// 形态：本平台只有推荐快照 + 链接直达，无真搜索、无弹幕。
// categories() 一律返回 []；recommendRooms() 返回推荐快照一页
// （weibo_api.dart directory()）；searchRooms() / searchAnchors()
// 只解析直播链接得 liveId 再调详情，解析不出时在推荐快照里按昵称
// 本地过滤（不是全站搜索）；弹幕：无（LiveSite 默认空实现）。
//
// 详情/取流（Pure Live lib/shared/platforms/weibo/weibo_api.dart 为准）：
//   推荐：GET https://weibo.com/l/!/2/wblive/pc_recommend/list.json
//     ?count=100&uid= → data.data[]（liveid / uid / nickname / cover）
//   详情：GET https://weibo.com/l/!/2/wblive/room/show_pc_live.json
//     ?live_id={liveId} → data（liveId / user.uid / status / title /
//     cover / watch_limit / pay_live_status / play_switch /
//     live_origin_flv_url / live_origin_hls_url）
//     status：1 = 在播，3 = 回放，5 = 已结束；play_switch == 0 是停播，
//     watch_limit != 0 是受限（仅 App / 仅好友 / 仅自己 / 付费）。
//   只有一档“原画”；每次播放/恢复都重新取详情拿新 URL，不缓存签名
//   URL（参照注明未观察到过期约定）。access != public 或非 live 状态
//   播不了。
//
// liveId 格式（二选一）：`1022:232132` + 16 位数字，或
// `1042152:` + 32 位小写十六进制。UID 不是 liveId，不能拿 UID 当房间号。
// 流地址（含签名查询参数）原样保留，不拼接。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WeiboSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .weibo
    private let http = HTTPClient.shared

    private static let origin = "https://weibo.com"

    /// Directory / detail request headers (Pure Live's WeiboApi.headers).
    private static let apiHeaders: [String: String] = [
        "Referer": "https://weibo.com/l/wblive/",
        "User-Agent": "Mozilla/5.0",
    ]

    /// Playback headers (Pure Live's WeiboApi.playHeaders).
    private static let playHeaders: [String: String] = [
        "Referer": "https://weibo.com/l/wblive/",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    ]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] { [] }

    /// The recommendation snapshot, one page (Pure Live's directory()).
    /// Rooms carry no title / viewer count in the snapshot — title is
    /// the nickname, and live status is the snapshot's claim, not a
    /// per-room check (detail is fetched on open).
    func recommendRooms() async throws -> [LiveRoom] {
        let json = try await http.getJSON(
            "\(Self.origin)/l/!/2/wblive/pc_recommend/list.json?count=100&uid=",
            headers: Self.apiHeaders)
        return try Self.rooms(fromDirectory: json)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page <= 1 else { return [] }
        return try await recommendRooms()
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { [] }

    // MARK: - Search (link only, then local snapshot filter)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    private func search(keyword: String) async throws -> [LiveRoom] {
        if let liveID = Self.parseLink(keyword) {
            guard let detail = try? await fetchDetail(liveID: liveID) else { return [] }
            return [detail.room]
        }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        // Only the current recommendation snapshot is filtered.
        // This is not a full-site search and does not establish
        // live status.
        guard let rooms = try? await recommendRooms() else { return [] }
        return rooms.filter { $0.anchorName.lowercased().contains(query) }
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let liveID = Self.parseLink(roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return try await fetchDetail(liveID: liveID).room
    }

    // MARK: - Play URLs (single "原画" quality, fresh detail every time)

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let liveID = Self.parseLink(room.roomID) else { return [] }
        // No observed URL expiry contract: refresh at each new
        // playback attempt instead of caching signed URLs.
        guard let detail = try? await fetchDetail(liveID: liveID),
              detail.isLive, detail.access == .isPublic else { return [] }
        return detail.mediaURLs.compactMap { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return PlayStream(
                url: url,
                quality: "原画",
                line: urlString.lowercased().contains(".flv") ? "FLV" : "HLS",
                headers: Self.playHeaders
            )
        }
    }

    // MARK: - Detail fetch

    /// Parsed detail (Pure Live's WeiboLiveDetail).
    struct Detail {
        var room: LiveRoom
        var isLive: Bool
        var access: Access
        var mediaURLs: [String]
    }

    enum Access {
        case isPublic
        case restricted
        case disabled
    }

    private func fetchDetail(liveID: String) async throws -> Detail {
        guard Self.validateLiveID(liveID) != nil else {
            throw LiveSiteError.roomNotFound(liveID)
        }
        let encoded = liveID.replacingOccurrences(of: ":", with: "%3A")
        let json = try await http.getJSON(
            "\(Self.origin)/l/!/2/wblive/room/show_pc_live.json?live_id=\(encoded)",
            headers: Self.apiHeaders)
        return try Self.detail(fromJSON: json, expectedLiveID: liveID)
    }

    /// Pure parser for the room/show_pc_live response.
    /// Testable without the network.
    static func detail(fromJSON json: JSONValue, expectedLiveID: String) throws -> Detail {
        guard validateLiveID(expectedLiveID) != nil else {
            throw LiveSiteError.roomNotFound(expectedLiveID)
        }
        let item = try successData(json)
        guard let liveID = item["liveId"].stringValue,
              validateLiveID(liveID) != nil, liveID == expectedLiveID else {
            throw LiveSiteError.invalidResponse
        }
        let user = item["user"]
        guard !user.isNull, let ownerID = user["uid"].intValue, ownerID >= 1 else {
            throw LiveSiteError.invalidResponse
        }
        let status = item["status"].intValue ?? -1
        let watchLimit = item["watch_limit"].intValue ?? 0
        let playSwitch = item["play_switch"].intValue ?? 0
        let access: Access
        if playSwitch == 0 {
            access = .disabled
        } else if watchLimit != 0 {
            access = .restricted
        } else {
            access = .isPublic
        }
        let isLive = status == 1
        // HLS-labelled fields can contain FLV; keep the URLs without
        // fabricating quality. No media escapes for restricted /
        // disabled / replay states.
        var mediaURLs: [String] = []
        if isLive {
            for key in ["live_origin_flv_url", "live_origin_hls_url"] {
                if let url = item[key].stringValue, !url.isEmpty, !mediaURLs.contains(url) {
                    mediaURLs.append(url)
                }
            }
        }
        let title = item["title"].stringValue ?? ""
        let nickname = user["screenName"].stringValue ?? ""
        let room = LiveRoom(
            id: "weibo-\(liveID)",
            platform: .weibo,
            roomID: liveID,
            title: title.isEmpty ? nickname : title,
            anchorName: nickname,
            anchorAvatarURL: Self.imageURL(user["profileImageUrl"].stringValue),
            coverURL: Self.imageURL(item["cover"].stringValue),
            categoryName: "微博直播",
            viewerCount: 0,
            isLive: isLive
        )
        return Detail(room: room, isLive: isLive, access: access, mediaURLs: mediaURLs)
    }

    /// Pure parser for the pc_recommend snapshot.
    /// Testable without the network.
    static func rooms(fromDirectory json: JSONValue) throws -> [LiveRoom] {
        let rows = try successData(json)["data"].arrayValue
        guard rows.count <= 500 else { throw LiveSiteError.invalidResponse }
        var out: [LiveRoom] = []
        var seen: Set<String> = []
        for row in rows {
            guard let liveID = row["liveid"].stringValue,
                  validateLiveID(liveID) != nil,
                  let ownerID = row["uid"].intValue, ownerID >= 1,
                  let nickname = row["nickname"].stringValue, !nickname.isEmpty,
                  seen.insert(liveID).inserted else { continue }
            out.append(LiveRoom(
                id: "weibo-\(liveID)",
                platform: .weibo,
                roomID: liveID,
                title: nickname,
                anchorName: nickname,
                anchorAvatarURL: nil,
                coverURL: Self.imageURL(row["cover"].stringValue),
                categoryName: "微博直播",
                viewerCount: 0,
                isLive: true
            ))
        }
        return out
    }

    /// code == 100000 && error_code == 0, else the platform's own
    /// error. Testable without the network.
    static func successData(_ json: JSONValue) throws -> JSONValue {
        guard json["code"].intValue == 100_000, json["error_code"].intValue == 0 else {
            throw LiveSiteError.message("微博返回了错误")
        }
        let data = json["data"]
        guard !data.isNull else { throw LiveSiteError.invalidResponse }
        return data
    }

    // MARK: - liveId parsing (Pure Live's weibo_link.dart)

    /// `1022:232132` + 16 digits, or `1042152:` + 32 lowercase hex.
    /// Testable without the network.
    static func validateLiveID(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"^(?:1022:232132[0-9]{16}|1042152:[0-9a-f]{32})$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Bare liveId, or a watch URL /l/wblive/p/show/{id} (or
    /// /l/wblive/m/show/{id}). A profile UID is not a liveId.
    /// Testable without the network.
    static func parseLink(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("\\") || value.contains(" ") || value.contains("\t") || value.contains("\n") { return nil }
        if let id = validateLiveID(value) { return id }
        guard value.hasPrefix("http://") || value.hasPrefix("https://"),
              let url = URL(string: value),
              url.host == "weibo.com" || url.host == "www.weibo.com",
              url.user == nil,
              (url.port == nil || url.port == 443 || url.port == 80) else { return nil }
        // Inspect the path before URL normalizes dot segments; only
        // the identifier's colon may be %-escaped.
        guard let schemeEnd = value.range(of: "://") else { return nil }
        let authorityAndPath = String(value[schemeEnd.upperBound...]).components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        guard let slash = authorityAndPath.firstIndex(of: "/") else { return nil }
        let path = String(authorityAndPath[slash...])
        guard let match = firstMatch(pattern: #"^/l/wblive/[pm]/show/([^/]+)/?$"#, in: path) else { return nil }
        let id = match.replacingOccurrences(of: "%3a", with: ":", options: .caseInsensitive)
        return validateLiveID(id)
    }

    /// First capture group of a one-group pattern, or nil.
    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
