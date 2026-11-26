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

    /// Live danmaku stream for a room. Real adapters open the
    /// platform's danmaku channel and yield items as they arrive; the
    /// default implementation yields nothing, so callers fall back to
    /// `sampleDanmaku` (stubs) or show no danmaku (real adapters whose
    /// channel is not implemented yet).
    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem>
}

extension LiveSite {
    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { $0.finish() }
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
