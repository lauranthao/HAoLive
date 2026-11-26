// HistoryStore.swift
// HAo Live — local watch history. Stored on device only; capped at 100.

import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let key = "hao.live.history.v1"
    private let cap = 100

    init() {
        load()
    }

    /// Record a room visit: newest first, one entry per room.
    func record(_ room: LiveRoom) {
        entries.removeAll { $0.room.id == room.id }
        entries.insert(HistoryEntry(room: room, watchedAt: Date()), at: 0)
        if entries.count > cap {
            entries = Array(entries.prefix(cap))
        }
        save()
    }

    func clear() {
        entries = []
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
