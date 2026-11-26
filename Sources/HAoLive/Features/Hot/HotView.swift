// HotView.swift
// HAo Live — recommended rooms across platforms, with a platform filter.

import SwiftUI

struct HotView: View {
    @State private var selectedPlatform: LivePlatform?
    @State private var rooms: [LiveRoom] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            platformChips
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if rooms.isEmpty {
                ContentUnavailableView("暂无推荐", systemImage: "flame")
                    .padding(.top, 60)
            } else {
                RoomGrid(rooms: rooms)
                    .padding(HaoLiveDesign.pagePadding)
            }
        }
        .navigationTitle("热门")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .task(id: selectedPlatform) { await load() }
    }

    private var platformChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", selected: selectedPlatform == nil) {
                    selectedPlatform = nil
                }
                ForEach(LivePlatform.allCases, id: \.self) { platform in
                    chip(title: platform.shortName, selected: selectedPlatform == platform) {
                        selectedPlatform = platform
                    }
                }
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? HaoLiveDesign.liveRed : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let sites: [any LiveSite]
        if let selectedPlatform, let site = SiteRegistry.site(for: selectedPlatform) {
            sites = [site]
        } else {
            sites = SiteRegistry.sites
        }
        var merged: [LiveRoom] = []
        for site in sites {
            if let list = try? await site.recommendRooms() {
                merged.append(contentsOf: list)
            }
        }
        rooms = merged
    }
}
