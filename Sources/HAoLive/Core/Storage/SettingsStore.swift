// SettingsStore.swift
// HAo Live — settings: theme, player, danmaku, cache. Local only.

import Combine
import Foundation

enum HaoLiveTheme: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var theme: HaoLiveTheme = .system {
        didSet { save() }
    }
    @Published var preferredQuality: String = "" {
        didSet { save() }
    }
    @Published var preferredLine: String = "" {
        didSet { save() }
    }
    @Published var danmakuEnabled: Bool = true {
        didSet { save() }
    }
    @Published var danmakuFontSize: Double = 14 {
        didSet { save() }
    }
    @Published var danmakuOpacity: Double = 0.9 {
        didSet { save() }
    }
    @Published var blockedKeywords: [String] = [] {
        didSet { save() }
    }

    private struct Saved: Codable {
        var theme: HaoLiveTheme
        var preferredQuality: String
        var preferredLine: String
        var danmakuEnabled: Bool
        var danmakuFontSize: Double
        var danmakuOpacity: Double
        var blockedKeywords: [String]
    }

    private let key = "hao.live.settings.v1"

    init() {
        load()
    }

    /// Approximate local cache size (favorites + history JSON).
    var cacheSizeText: String {
        let defaults = UserDefaults.standard
        var bytes = 0
        for key in ["hao.live.favorites.v1", "hao.live.history.v1", key] {
            bytes += defaults.data(forKey: key)?.count ?? 0
        }
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }

    func clearCache() {
        UserDefaults.standard.removeObject(forKey: "hao.live.favorites.v1")
        UserDefaults.standard.removeObject(forKey: "hao.live.history.v1")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        theme = decoded.theme
        preferredQuality = decoded.preferredQuality
        preferredLine = decoded.preferredLine
        danmakuEnabled = decoded.danmakuEnabled
        danmakuFontSize = decoded.danmakuFontSize
        danmakuOpacity = decoded.danmakuOpacity
        blockedKeywords = decoded.blockedKeywords
    }

    private func save() {
        let saved = Saved(
            theme: theme,
            preferredQuality: preferredQuality,
            preferredLine: preferredLine,
            danmakuEnabled: danmakuEnabled,
            danmakuFontSize: danmakuFontSize,
            danmakuOpacity: danmakuOpacity,
            blockedKeywords: blockedKeywords
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
