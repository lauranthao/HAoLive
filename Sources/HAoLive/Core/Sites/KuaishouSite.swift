// KuaishouSite.swift
// HAo Live — STUB Kuaishou adapter. No network yet; real adapter is the next leg.

import Foundation

final class KuaishouSite: StubLiveSite, @unchecked Sendable {
    init() {
        super.init(
            platform: .kuaishou,
            sampleAnchors: ["快手老铁", "乡村生活", "美食家", "搞笑段子"],
            sampleCategories: ["生活", "美食", "搞笑", "游戏"]
        )
    }
}
