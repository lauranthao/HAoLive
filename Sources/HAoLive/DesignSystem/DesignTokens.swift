// DesignTokens.swift
// HAo Live — HAo's own design tokens. Not Pure Live's look:
// large titles, 16:9 room cards with a red LIVE badge, platform
// colour chips, generous corner radii, system-adaptive colours.

import SwiftUI

enum HaoLiveDesign {
    /// 16 pt page side margin, used by every list page.
    static let pagePadding: CGFloat = 16
    /// Card radius (room cards, category cards).
    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    /// Control-sized rounded rects: search fields, category icons,
    /// centred player error card. One value for one kind of element.
    static let controlCornerRadius: CGFloat = 12
    /// Transient player HUD cards (volume / brightness centre card).
    static let hudCornerRadius: CGFloat = 8
    /// Two-column room grid gap.
    static let gridSpacing: CGFloat = 12
    /// Top inset for every loading spinner / empty / error state
    /// (Hot, 分区, CategoryRooms, Search, Favorites all the same).
    static let emptyStateTopPadding: CGFloat = 60
    /// Filter-chip padding — every chip row in the app (platform,
    /// status, tag, starred, search history) is the same size.
    static let chipHorizontalPadding: CGFloat = 14
    static let chipVerticalPadding: CGFloat = 7

    /// The live red used for LIVE badges and the accent.
    static let liveRed = Color(red: 0.91, green: 0.22, blue: 0.21)

    static let cardBackground = Color(.secondarySystemBackground)
}

/// Motion tokens (HAoMusic's AppAnimation, same values): one easing
/// curve family for the whole app — control bars, cards, toast.
enum HaoLiveAnimation {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.25)
    static let smooth = Animation.easeInOut(duration: 0.35)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    static let staggerDelay = 0.04
    static let maxStaggerDelay = 0.4

    static func stagger(for index: Int) -> Double {
        min(Double(index) * staggerDelay, maxStaggerDelay)
    }
}

extension Color {
    /// Build a Color from a "#RRGGBB" hex string.
    init(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
