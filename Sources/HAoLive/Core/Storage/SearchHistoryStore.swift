// SearchHistoryStore.swift
// HAo Live — search history (HAoMusic's SearchHistory: up to 10
// keywords in UserDefaults, newest first). Shown as chips on the
// empty search page; tapping one searches it again.

import Foundation
import Combine

@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    private let key = "haoLive.searchHistory"
    private let maxCount = 10

    @Published private(set) var keywords: [String] = []

    private init() {
        keywords = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        keywords.removeAll { $0 == trimmed }
        keywords.insert(trimmed, at: 0)
        if keywords.count > maxCount {
            keywords = Array(keywords.prefix(maxCount))
        }
        UserDefaults.standard.set(keywords, forKey: key)
    }

    func clear() {
        keywords = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
