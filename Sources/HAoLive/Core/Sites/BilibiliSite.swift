// BilibiliSite.swift
// HAo Live — STUB Bilibili adapter. No network yet; real adapter is the next leg.

import Foundation

final class BilibiliSite: StubLiveSite, @unchecked Sendable {
    init() {
        super.init(
            platform: .bilibili,
            sampleAnchors: ["阿梓", "小熊", "电竞老王", "音乐小站"],
            sampleCategories: ["游戏", "娱乐", "音乐", "学习"]
        )
    }
}
