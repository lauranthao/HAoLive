// SettingsStore.swift
// HAo Live — settings: theme, player, danmaku, cache. Local only.
//
// Danmaku fields follow Pure Live's DanmakuSettingsController
// (practical subset for the SwiftUI lanes: speed in px/s, display
// area fraction, font weight / letter spacing, stroke, max visible
// count, collapse-repeated). New fields carry defaults, so older
// saved settings (v1) still decode — the synthesized Codable init
// uses decodeIfPresent for defaulted properties.

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
    /// Preferred quality on Wi-Fi (Pure Live's preferResolution;
    /// wzgrx default 原画, same as cellular).
    @Published var preferredQuality: String = "原画" {
        didSet { save() }
    }
    /// Preferred quality on cellular (Pure Live's
    /// preferResolutionCellular; wzgrx default 原画).
    @Published var preferredQualityCellular: String = "原画" {
        didSet { save() }
    }
    @Published var preferredLine: String = "" {
        didSet { save() }
    }
    /// mpv hardware decoding (Pure Live's hwdec setting):
    /// auto / auto-safe / no. wzgrx default is auto-safe
    /// (hardwareDecoding on -> preferredHardwareDecoder).
    /// Applied when the engine is created.
    @Published var hwdecMode: String = "auto-safe" {
        didSet { save() }
    }

    // MARK: - Danmaku (Pure Live's DanmakuSettingsController, subset)
    @Published var danmakuEnabled: Bool = true {
        didSet { save() }
    }
    @Published var danmakuFontSize: Double = 14 {
        didSet { save() }
    }
    @Published var danmakuOpacity: Double = 0.9 {
        didSet { save() }
    }
    /// Scroll speed in points per second (Pure Live: 120 px/s).
    @Published var danmakuSpeed: Double = 120 {
        didSet { save() }
    }
    /// Fraction of the overlay height danmaku may use (0.25...1.0).
    @Published var danmakuArea: Double = 1.0 {
        didSet { save() }
    }
    /// Font weight 100...900 (Pure Live default 500).
    @Published var danmakuFontWeight: Int = 500 {
        didSet { save() }
    }
    @Published var danmakuLetterSpacing: Double = 0 {
        didSet { save() }
    }
    @Published var danmakuStrokeEnabled: Bool = true {
        didSet { save() }
    }
    /// Stroke width 0...4 (Pure Live default 1.5).
    @Published var danmakuStrokeWidth: Double = 1.5 {
        didSet { save() }
    }
    /// Max messages on screen at once (Pure Live default 48).
    @Published var danmakuMaxVisibleCount: Int = 48 {
        didSet { save() }
    }
    /// Collapse identical messages posted within a few seconds.
    @Published var danmakuCollapseRepeated: Bool = false {
        didSet { save() }
    }
    @Published var blockedKeywords: [String] = [] {
        didSet { save() }
    }
    @Published var blockedUsers: [String] = [] {
        didSet { save() }
    }

    /// Starred category ids ("{platform}-{id}"), shown first.
    @Published var favoriteCategoryIDs: [String] = [] {
        didSet { save() }
    }

    private struct Saved: Codable {
        var theme: HaoLiveTheme = .system
        var preferredQuality: String = "原画"
        var preferredQualityCellular: String = "原画"
        var preferredLine: String = ""
        var hwdecMode: String = "auto-safe"
        var danmakuEnabled: Bool = true
        var danmakuFontSize: Double = 14
        var danmakuOpacity: Double = 0.9
        var danmakuSpeed: Double = 120
        var danmakuArea: Double = 1.0
        var danmakuFontWeight: Int = 500
        var danmakuLetterSpacing: Double = 0
        var danmakuStrokeEnabled: Bool = true
        var danmakuStrokeWidth: Double = 1.5
        var danmakuMaxVisibleCount: Int = 48
        var danmakuCollapseRepeated: Bool = false
        var blockedKeywords: [String] = []
        var blockedUsers: [String] = []
        var favoriteCategoryIDs: [String] = []
    }

    private let key = "hao.live.settings.v1"

    init() {
        load()
    }

    /// Image-cache size (URLCache disk + memory). The cover cache
    /// (NSCache) has no measurable size, so this is the number shown.
    var imageCacheSizeText: String {
        let bytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        theme = decoded.theme
        // Build 11: the old "" default ("automatic") is replaced by
        // wzgrx's 原画 default; an empty saved value means the user
        // never chose, so it migrates to 原画. An explicit "auto"
        // hwdec migrates to wzgrx's auto-safe default the same way.
        preferredQuality = decoded.preferredQuality.isEmpty ? "原画" : decoded.preferredQuality
        preferredQualityCellular = decoded.preferredQualityCellular.isEmpty ? "原画" : decoded.preferredQualityCellular
        preferredLine = decoded.preferredLine
        hwdecMode = decoded.hwdecMode == "auto" ? "auto-safe" : decoded.hwdecMode
        danmakuEnabled = decoded.danmakuEnabled
        danmakuFontSize = decoded.danmakuFontSize
        danmakuOpacity = decoded.danmakuOpacity
        danmakuSpeed = decoded.danmakuSpeed
        danmakuArea = decoded.danmakuArea
        danmakuFontWeight = decoded.danmakuFontWeight
        danmakuLetterSpacing = decoded.danmakuLetterSpacing
        danmakuStrokeEnabled = decoded.danmakuStrokeEnabled
        danmakuStrokeWidth = decoded.danmakuStrokeWidth
        danmakuMaxVisibleCount = decoded.danmakuMaxVisibleCount
        danmakuCollapseRepeated = decoded.danmakuCollapseRepeated
        blockedKeywords = decoded.blockedKeywords
        blockedUsers = decoded.blockedUsers
        favoriteCategoryIDs = decoded.favoriteCategoryIDs
    }

    private func save() {
        let saved = Saved(
            theme: theme,
            preferredQuality: preferredQuality,
            preferredQualityCellular: preferredQualityCellular,
            preferredLine: preferredLine,
            hwdecMode: hwdecMode,
            danmakuEnabled: danmakuEnabled,
            danmakuFontSize: danmakuFontSize,
            danmakuOpacity: danmakuOpacity,
            danmakuSpeed: danmakuSpeed,
            danmakuArea: danmakuArea,
            danmakuFontWeight: danmakuFontWeight,
            danmakuLetterSpacing: danmakuLetterSpacing,
            danmakuStrokeEnabled: danmakuStrokeEnabled,
            danmakuStrokeWidth: danmakuStrokeWidth,
            danmakuMaxVisibleCount: danmakuMaxVisibleCount,
            danmakuCollapseRepeated: danmakuCollapseRepeated,
            blockedKeywords: blockedKeywords,
            blockedUsers: blockedUsers,
            favoriteCategoryIDs: favoriteCategoryIDs
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
