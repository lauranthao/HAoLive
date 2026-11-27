// CategoryRoomsView.swift
// HAo Live — one category's rooms on their own page: its own title,
// room list, pagination and pull-to-refresh. Tapping a category in
// 分区 pushes here instead of loading rooms inline below the grid
// (chen 2026-11-27: 分区点开分类要做单独页面).

import SwiftUI

struct CategoryRoomsView: View {
    let category: LiveCategory

    @State private var rooms: [LiveRoom] = []
    @State private var page = 1
    @State private var canLoadMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var roomsError: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, 40)
            } else if let error = roomsError, rooms.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(error))
                    Button("重试") { Task { await loadRooms(reset: true) } }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 40)
            } else if rooms.isEmpty {
                ContentUnavailableView("这个分区暂无房间", systemImage: "square.grid.2x2")
                    .padding(.top, 40)
            } else {
                RoomGrid(rooms: rooms)
                    .padding(HaoLiveDesign.pagePadding)
                if isLoadingMore {
                    ProgressView().padding(.vertical, 16)
                } else if canLoadMore {
                    Button("加载更多") { Task { await loadRooms(reset: false) } }
                        .font(.subheadline)
                        .padding(.vertical, 16)
                }
            }
        }
        .refreshable { await loadRooms(reset: true) }
        .navigationTitle(category.name)
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .task { await loadRooms(reset: true) }
    }

    private func loadRooms(reset: Bool) async {
        guard let site = SiteRegistry.site(for: category.platform) else { return }
        if reset {
            isLoading = true
            roomsError = nil
            page = 1
        } else {
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        let targetPage = reset ? 1 : page + 1
        do {
            let newRooms = try await site.categoryRooms(category, page: targetPage)
            if reset {
                rooms = newRooms
                page = 1
            } else {
                let seen = Set(rooms.map(\.id))
                rooms.append(contentsOf: newRooms.filter { !seen.contains($0.id) })
                page = targetPage
            }
            canLoadMore = !newRooms.isEmpty
        } catch {
            if reset {
                roomsError = error.localizedDescription
            } else {
                roomsError = nil // load-more failure: footer just stays
                canLoadMore = true
            }
        }
    }
}
