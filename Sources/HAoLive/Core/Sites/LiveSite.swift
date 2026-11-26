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

    /// Rooms inside one category.
    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom]

    /// Search rooms by keyword.
    func searchRooms(keyword: String) async throws -> [LiveRoom]

    /// Search anchors by keyword.
    func searchAnchors(keyword: String) async throws -> [LiveRoom]

    /// Full detail for one room.
    func roomDetail(roomID: String) async throws -> LiveRoom

    /// Playable streams for one room (quality + line).
    func playURLs(roomID: String) async throws -> [PlayStream]

    /// Sample danmaku lines for the room (stub data in this skeleton;
    /// the real adapter will open the platform's danmaku channel).
    func sampleDanmaku(roomID: String) async -> [DanmakuItem]
}

enum LiveSiteError: Error, LocalizedError {
    case notImplemented
    case roomNotFound(String)
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "该平台暂未接入"
        case .roomNotFound(let id): return "找不到房间 \(id)"
        case .networkUnavailable: return "网络不可用"
        }
    }
}
