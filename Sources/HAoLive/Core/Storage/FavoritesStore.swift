// FavoritesStore.swift
// HAo Live — locally followed rooms. Stored on device only; no account.
//
// A favorite is an entry (room + user tags + when it was added),
// not a dead snapshot: the view re-checks each room's live status
// on open and updates the stored copy (title / viewers / live).
// v2 storage; v1 ([LiveRoom]) migrates on first load.

import Combine
import Foundation

/// One followed room: the room as last seen, plus the user's tags
/// and when it was followed (drives the "recent" sort).
struct FavoriteEntry: Identifiable, Hashable, Codable, Sendable {
    var room: LiveRoom
    var tags: [String]
    var addedAt: Date

    var id: String { room.id }
}

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var entries: [FavoriteEntry] = []
    @Published private(set) var lastRefreshAt: Date?

    /// The rooms, newest first — kept for callers that only need rooms.
    var favorites: [LiveRoom] { entries.map(\.room) }

    /// All tags in use, sorted.
    var allTags: [String] {
        Array(Set(entries.flatMap(\.tags))).sorted()
    }

    private let key = "hao.live.favorites.v2"
    private let legacyKey = "hao.live.favorites.v1"

    init() {
        load()
    }

    func isFavorite(_ room: LiveRoom) -> Bool {
        entries.contains { $0.room.id == room.id }
    }

    func toggle(_ room: LiveRoom) {
        if isFavorite(room) {
            entries.removeAll { $0.room.id == room.id }
        } else {
            entries.insert(FavoriteEntry(room: room, tags: [], addedAt: Date()), at: 0)
        }
        save()
    }

    func remove(_ room: LiveRoom) {
        entries.removeAll { $0.room.id == room.id }
        save()
    }

    func tags(for room: LiveRoom) -> [String] {
        entries.first { $0.room.id == room.id }?.tags ?? []
    }

    func setTags(_ tags: [String], for room: LiveRoom) {
        guard let index = entries.firstIndex(where: { $0.room.id == room.id }) else { return }
        entries[index].tags = tags
        save()
    }

    /// Re-check every favorite's live status / title / viewers from
    /// the platform (parallel; a failed fetch keeps the stored copy).
    /// Call on open and on pull-to-refresh.
    func refreshStatuses() async {
        let rooms = entries.map(\.room)
        let updated = await withTaskGroup(of: (String, LiveRoom?).self) { group in
            for room in rooms {
                group.addTask {
                    guard let site = SiteRegistry.site(for: room.platform) else { return (room.id, nil) }
                    let detail = try? await site.roomDetail(roomID: room.roomID)
                    return (room.id, detail)
                }
            }
            var out: [String: LiveRoom] = [:]
            for await (id, detail) in group {
                if let detail { out[id] = detail }
            }
            return out
        }
        for index in entries.indices {
            if let detail = updated[entries[index].room.id] {
                entries[index].room = detail
            }
        }
        lastRefreshAt = Date()
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([FavoriteEntry].self, from: data) {
            entries = decoded
            return
        }
        // v1 migration: bare rooms become untagged entries.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([LiveRoom].self, from: data) {
            entries = decoded.map { FavoriteEntry(room: $0, tags: [], addedAt: Date()) }
            UserDefaults.standard.removeObject(forKey: legacyKey)
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
