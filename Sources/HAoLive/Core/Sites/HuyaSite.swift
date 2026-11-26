// HuyaSite.swift
// HAo Live — STUB Huya adapter. No network yet; real adapter is the next leg.

import Foundation

final class HuyaSite: StubLiveSite, @unchecked Sendable {
    init() {
        super.init(
            platform: .huya,
            sampleAnchors: ["虎牙小虎", "和平精英", "二次元", "户外大表哥"],
            sampleCategories: ["游戏", "二次元", "户外", "娱乐"]
        )
    }
}
