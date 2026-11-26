// DanmakuItem.swift
// HAo Live — one danmaku (live comment) message.

import Foundation

struct DanmakuItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var roomID: String
    var user: String
    var text: String
    /// Hex colour string; empty means "platform default colour".
    var colorHex: String
    var timestamp: Date

    init(id: String = UUID().uuidString, roomID: String, user: String, text: String, colorHex: String = "", timestamp: Date = Date()) {
        self.id = id
        self.roomID = roomID
        self.user = user
        self.text = text
        self.colorHex = colorHex
        self.timestamp = timestamp
    }
}
