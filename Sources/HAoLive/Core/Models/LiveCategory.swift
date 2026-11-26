// LiveCategory.swift
// HAo Live — a browse category belonging to one platform.

import Foundation

struct LiveCategory: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var platform: LivePlatform
    var name: String
    var iconName: String?
}
