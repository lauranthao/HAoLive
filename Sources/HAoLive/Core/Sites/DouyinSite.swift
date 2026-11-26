// DouyinSite.swift
// HAo Live — STUB Douyin adapter. No network yet; real adapter is the next leg.

import Foundation

final class DouyinSite: StubLiveSite, @unchecked Sendable {
    init() {
        super.init(
            platform: .douyin,
            sampleAnchors: ["抖音小姐姐", "带货一哥", "才艺小王子", "旅行日记"],
            sampleCategories: ["才艺", "购物", "旅行", "生活"]
        )
    }
}
