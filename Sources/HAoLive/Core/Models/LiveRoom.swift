// LiveRoom.swift
// HAo Live — the unified room model shared by all platform adapters.

import Foundation

/// One live room, in platform-independent form.
/// Every platform adapter converts its own room JSON into this shape,
/// so the UI never sees platform-specific models.
struct LiveRoom: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var platform: LivePlatform
    var roomID: String
    var title: String
    var anchorName: String
    var anchorAvatarURL: URL?
    var coverURL: URL?
    var categoryName: String?
    var viewerCount: Int
    var isLive: Bool

    /// Platform payload carried from the list item that produced
    /// this room, as compact JSON text (Pure Live's LiveRoom.data).
    /// Kuaishou stores its playUrls descriptors here: playback
    /// uses them directly instead of re-fetching the (rate-limited)
    /// room page. Nil when the platform has no list payload.
    var playDataJSON: String? = nil

    /// Stable identity across platforms for dedupe in merged search:
    /// same anchor + same title on two platforms is treated as one room.
    var dedupeKey: String {
        "\(anchorName)|\(title)"
    }

    var viewerCountText: String {
        if viewerCount >= 10_000 {
            return String(format: "%.1f万", Double(viewerCount) / 10_000.0)
        }
        return "\(viewerCount)"
    }
}

/// One entry in the local watch history.
struct HistoryEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String { room.id + "@" + String(watchedAt.timeIntervalSince1970) }
    var room: LiveRoom
    var watchedAt: Date
}
