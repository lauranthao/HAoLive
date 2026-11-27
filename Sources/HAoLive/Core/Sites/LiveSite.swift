// LiveSite.swift
// HAo Live — the platform-adapter contract.
// Same shape of capability as Pure Live's LiveSite (categories,
// recommendations, search, room detail, play URLs, danmaku),
// re-implemented from scratch for HAo Live.

import Foundation

/// What every platform adapter must provide.
/// The UI only talks to this protocol, never to a platform directly.
protocol LiveSite: AnyObject, Sendable {
    var platform: LivePlatform { get }

    /// Browse categories of this platform.
    func categories() async throws -> [LiveCategory]

    /// Recommended rooms on the platform's front page.
    func recommendRooms() async throws -> [LiveRoom]

    /// Recommended rooms, page N (1-based). Default: page 1 only.
    func recommendRooms(page: Int) async throws -> [LiveRoom]

    /// Rooms inside one category.
    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom]

    /// Rooms inside one category, page N (1-based). Default: page 1 only.
    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom]

    /// Search rooms by keyword.
    func searchRooms(keyword: String) async throws -> [LiveRoom]

    /// Search rooms by keyword, page N (1-based). Default: page 1 only.
    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom]

    /// Search anchors by keyword.
    func searchAnchors(keyword: String) async throws -> [LiveRoom]

    /// Search anchors by keyword, page N (1-based). Default: page 1 only.
    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom]

    /// Full detail for one room.
    func roomDetail(roomID: String) async throws -> LiveRoom

    /// Playable streams for one room (quality + line). The room
    /// carries its list payload (LiveRoom.playDataJSON) when the
    /// platform ships play URLs with the list item — Pure Live's
    /// getPlayUrls(liveroom:) reads it instead of re-fetching.
    func playURLs(room: LiveRoom) async throws -> [PlayStream]

    /// Live danmaku stream for a room. Real adapters open the
    /// platform's danmaku channel and yield items as they arrive;
    /// the default implementation yields nothing, so rooms whose
    /// channel is not implemented yet simply show no danmaku.
    /// (There is deliberately no sample/fake danmaku anywhere:
    /// a room with no live channel shows an honest empty state.)
    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem>
}

extension LiveSite {
    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { $0.finish() }
    }

    /// Paged lists default to page 1 only; adapters override the
    /// paged methods where the platform's API actually pages.
    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page <= 1 else { return [] }
        return try await recommendRooms()
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page <= 1 else { return [] }
        return try await categoryRooms(category)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        guard page <= 1 else { return [] }
        return try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        guard page <= 1 else { return [] }
        return try await searchAnchors(keyword: keyword)
    }
}

enum LiveSiteError: Error, LocalizedError {
    case notImplemented
    case roomNotFound(String)
    case networkUnavailable
    case httpStatus(Int)
    case invalidResponse
    /// The platform itself reported an error (rate limit, room gone...);
    /// the message is the platform's own wording.
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "该平台暂未接入"
        case .roomNotFound(let id): return "找不到房间 \(id)"
        case .networkUnavailable: return "网络不可用"
        case .httpStatus(let code): return "服务器返回错误 \(code)"
        case .invalidResponse: return "服务器返回了无法识别的数据"
        case .message(let text): return text
        }
    }
}
