// HistoryStore.swift
// HAo Live — local watch history. Stored on device only.
// Retention is by count (Pure Live's historyLimit: default 50;
// 0 = unlimited), with per-item delete. Newest first; re-watching
// a room moves it to the top.

import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    /// Max entries kept; 0 means unlimited. Pure Live presets:
    /// 20 / 50 / 100 / 200 / 500 / unlimited. Persisted separately
    /// so the setting lives with the data it governs.
    @Published var limit: Int = 50 {
        didSet {
            UserDefaults.standard.set(limit, forKey: limitKey)
            prune()
        }
    }

    private let key = "hao.live.history.v1"
    private let limitKey = "hao.live.history.limit.v1"

    init() {
        limit = UserDefaults.standard.object(forKey: limitKey) as? Int ?? 50
        load()
        prune()
    }

    /// Record a room visit: newest first, one entry per room.
    func record(_ room: LiveRoom) {
        entries.removeAll { $0.room.id == room.id }
        entries.insert(HistoryEntry(room: room, watchedAt: Date()), at: 0)
        prune()
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func remove(room: LiveRoom) {
        entries.removeAll { $0.room.id == room.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Drop everything past the count limit (0 = keep all).
    func prune() {
        guard limit > 0, entries.count > limit else { return }
        entries = Array(entries.prefix(limit))
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
