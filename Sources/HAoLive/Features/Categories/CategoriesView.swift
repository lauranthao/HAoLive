// CategoriesView.swift
// HAo Live — browse by platform, then by category.

import SwiftUI

struct CategoriesView: View {
    @State private var selectedPlatform: LivePlatform = .bilibili
    @State private var categories: [LiveCategory] = []
    @State private var selectedCategory: LiveCategory?
    @State private var rooms: [LiveRoom] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            platformRail
            categoryChips
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if rooms.isEmpty {
                ContentUnavailableView("这个分区暂无房间", systemImage: "square.grid.2x2")
                    .padding(.top, 60)
            } else {
                RoomGrid(rooms: rooms)
                    .padding(HaoLiveDesign.pagePadding)
            }
        }
        .navigationTitle("分区")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .task(id: selectedPlatform) { await loadCategories() }
        .task(id: selectedCategory) { await loadRooms() }
    }

    private var platformRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LivePlatform.allCases, id: \.self) { platform in
                    Button {
                        selectedPlatform = platform
                        selectedCategory = nil
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: platform.colorHex))
                                .frame(width: 8, height: 8)
                            Text(platform.shortName)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedPlatform == platform ? Color(hex: platform.colorHex).opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(selectedPlatform == platform ? Color(hex: platform.colorHex) : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .padding(.vertical, 8)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category.name)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedCategory?.id == category.id ? HaoLiveDesign.liveRed : Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(selectedCategory?.id == category.id ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .padding(.bottom, 8)
        }
    }

    private func loadCategories() async {
        guard let site = SiteRegistry.site(for: selectedPlatform) else { return }
        if let list = try? await site.categories() {
            categories = list
            selectedCategory = list.first
        }
    }

    private func loadRooms() async {
        guard let site = SiteRegistry.site(for: selectedPlatform),
              let category = selectedCategory else { return }
        isLoading = true
        defer { isLoading = false }
        rooms = (try? await site.categoryRooms(category)) ?? []
    }
}
