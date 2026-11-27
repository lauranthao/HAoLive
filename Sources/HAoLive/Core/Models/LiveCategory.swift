// LiveCategory.swift
// HAo Live — a browse category belonging to one platform.

import Foundation

struct LiveCategory: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var platform: LivePlatform
    var name: String
    var iconName: String?
    /// Category artwork when the platform's list API provides one
    /// (Douyu game_icon, Huya imgUrl). Nil when it doesn't.
    var iconURL: URL? = nil
}
