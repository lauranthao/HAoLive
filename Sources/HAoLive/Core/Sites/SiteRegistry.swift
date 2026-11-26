// SiteRegistry.swift
// HAo Live — the registry of platform adapters.
// The UI asks the registry, never a platform class directly,
// so adding a platform later is one line here.

import Foundation

enum SiteRegistry {
    /// All first-phase adapters, in display order.
    static let sites: [any LiveSite] = [
        BilibiliSite(),
        DouyuSite(),
        HuyaSite(),
        DouyinSite(),
        KuaishouSite(),
    ]

    static func site(for platform: LivePlatform) -> (any LiveSite)? {
        sites.first { $0.platform == platform }
    }
}
