// LivePlatform.swift
// HAo Live — the five first-phase live platforms.
// Platform identity only; no network code lives here.

import Foundation

/// The live platforms HAo Live supports in phase one.
/// Mirrors Pure Live's site-adapter idea (one adapter per platform),
/// but the set, order and presentation are HAo's own.
enum LivePlatform: String, CaseIterable, Codable, Hashable, Sendable {
    case bilibili
    case douyu
    case huya
    case douyin
    case kuaishou

    var displayName: String {
        switch self {
        case .bilibili: return "哔哩哔哩"
        case .douyu: return "斗鱼"
        case .huya: return "虎牙"
        case .douyin: return "抖音"
        case .kuaishou: return "快手"
        }
    }

    /// Short label shown on room cards.
    var shortName: String {
        switch self {
        case .bilibili: return "B站"
        case .douyu: return "斗鱼"
        case .huya: return "虎牙"
        case .douyin: return "抖音"
        case .kuaishou: return "快手"
        }
    }

    /// Brand colour as a hex string (models stay Foundation-only;
    /// views convert this to a Color).
    var colorHex: String {
        switch self {
        case .bilibili: return "#00A1D6"
        case .douyu: return "#FF7A00"
        case .huya: return "#FFAA00"
        case .douyin: return "#FE2C55"
        case .kuaishou: return "#FF5000"
        }
    }
}
