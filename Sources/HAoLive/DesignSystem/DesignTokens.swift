// DesignTokens.swift
// HAo Live — HAo's own design tokens. Not Pure Live's look:
// large titles, 16:9 room cards with a red LIVE badge, platform
// colour chips, generous corner radii, system-adaptive colours.

import SwiftUI

enum HaoLiveDesign {
    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    static let gridSpacing: CGFloat = 12
    static let pagePadding: CGFloat = 16

    /// The live red used for LIVE badges and the accent.
    static let liveRed = Color(red: 0.91, green: 0.22, blue: 0.21)

    static let cardBackground = Color(.secondarySystemBackground)
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
