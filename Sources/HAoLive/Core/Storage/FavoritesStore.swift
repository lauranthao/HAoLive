// FavoritesStore.swift
// HAo Live — locally followed rooms. Stored on device only; no account.

import Combine
import Foundation

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [LiveRoom] = []

    private let key = "hao.live.favorites.v1"

    init() {
        load()
    }

    func isFavorite(_ room: LiveRoom) -> Bool {
        favorites.contains { $0.id == room.id }
    }

    func toggle(_ room: LiveRoom) {
        if isFavorite(room) {
            favorites.removeAll { $0.id == room.id }
        } else {
            favorites.insert(room, at: 0)
        }
        save()
    }

    func remove(_ room: LiveRoom) {
        favorites.removeAll { $0.id == room.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LiveRoom].self, from: data) else { return }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
