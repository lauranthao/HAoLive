// FavoritesView.swift
// HAo Live — followed rooms grid. Local only; no account.

import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore

    var body: some View {
        ScrollView {
            if favoritesStore.favorites.isEmpty {
                ContentUnavailableView(
                    "还没有收藏的房间",
                    systemImage: "heart",
                    description: Text("在直播间点收藏，房间会出现在这里")
                )
                .padding(.top, 80)
            } else {
                RoomGrid(rooms: favoritesStore.favorites)
                    .padding(HaoLiveDesign.pagePadding)
            }
        }
        .navigationTitle("收藏")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
    }
}
