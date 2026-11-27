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

// MARK: - Room-link parser (Pure Live's WebSearchRoomParser host table)

/// Parse a pasted room link into (platform, roomID). Host table is
/// Pure Live's, for our five platforms only; short links are not
/// followed (no redirect chain), so paste the full room URL.
enum LiveURLParser {
    /// Segments that are pages, never room ids.
    private static let reserved = ["search", "category", "video", "user", "login"]

    static func parse(_ text: String) -> (platform: LivePlatform, roomID: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let first = segments.first, !reserved.contains(first) else { return nil }
        if isHost(host, domain: "huya.com") {
            guard first.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            return (.huya, first)
        }
        if isHost(host, domain: "douyu.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.douyu, first)
        }
        if isHost(host, domain: "douyin.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.douyin, first)
        }
        if isHost(host, domain: "kuaishou.com") {
            // live.kuaishou.com/u/{id}
            guard segments.count >= 2, segments[0] == "u", segments[1].allSatisfy(\.isNumber) else { return nil }
            return (.kuaishou, segments[1])
        }
        if isHost(host, domain: "bilibili.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.bilibili, first)
        }
        return nil
    }

    private static func isHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
