// DouyuSite.swift
// HAo Live — STUB Douyu adapter. No network yet; real adapter is the next leg.

import Foundation

final class DouyuSite: StubLiveSite, @unchecked Sendable {
    init() {
        super.init(
            platform: .douyu,
            sampleAnchors: ["斗鱼一哥", "户外阿强", "颜值小雨", "王者荣耀"],
            sampleCategories: ["游戏", "户外", "颜值", "体育"]
        )
    }
}
