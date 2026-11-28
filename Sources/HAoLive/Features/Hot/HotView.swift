// HotView.swift
// HAo Live — recommended rooms across platforms, with a platform filter.
// Platforms load in parallel; lists page (load-more footer);
// pull-to-refresh reloads; a failed load shows a retry, never a
// silent blank.

import SwiftUI

struct HotView: View {
    @State private var selectedPlatform: LivePlatform?
    @State private var rooms: [LiveRoom] = []
    @State private var page = 1
    @State private var canLoadMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var loadMoreFailed = false

    var body: some View {
        ScrollView {
            platformChips
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if let error = loadError, rooms.isEmpty {
                ContentUnavailableView(
                    "加载失败",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
                .padding(.top, 60)
                Button("重试") { Task { await load(reset: true) } }
                    .buttonStyle(.bordered)
            } else if rooms.isEmpty {
                ContentUnavailableView("暂无推荐", systemImage: "flame")
                    .padding(.top, 60)
            } else {
                RoomGrid(rooms: rooms)
                    .padding(HaoLiveDesign.pagePadding)
                loadMoreFooter
            }
        }
        .refreshable { await load(reset: true) }
        .navigationTitle("热门")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .task(id: selectedPlatform) { await load(reset: true) }
    }

    private var loadMoreFooter: some View {
        Group {
            if isLoadingMore {
                ProgressView().padding(.vertical, 16)
            } else if loadMoreFailed {
                Button("加载失败，点此重试") { Task { await loadMore() } }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if canLoadMore {
                Button("加载更多") { Task { await loadMore() } }
                    .font(.subheadline)
                    .padding(.vertical, 16)
            }
        }
    }

    private var platformChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", selected: selectedPlatform == nil) {
                    selectedPlatform = nil
                }
                ForEach(LivePlatform.allCases, id: \.self) { platform in
                    platformChip(platform: platform, selected: selectedPlatform == platform) {
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
        }
        .buttonStyle(.chip(isSelected: selected))
    }

    private func platformChip(platform: LivePlatform, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PlatformLogo(platform: platform, size: 18)
                Text(platform.shortName)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.chip(isSelected: selected))
    }

    private func sites() -> [any LiveSite] {
        if let selectedPlatform, let site = SiteRegistry.site(for: selectedPlatform) {
            return [site]
        }
        return SiteRegistry.sites
    }

    /// One page across the selected platforms, in parallel.
    /// Platforms keep their order (index-tagged task group);
    /// results merge round-robin (RoomSearchMerger
    /// .mergeInterleaved), so every platform's rooms show near
    /// the top instead of the first platforms' whole pages
    /// burying the rest; deduped by anchor + title.
    /// Returns the rooms plus whether EVERY platform errored (so the
    /// UI can tell "no more pages" apart from "network failed").
    private func loadPage(_ page: Int) async -> ([LiveRoom], Bool) {
        let sites = sites()
        let perPlatform = await withTaskGroup(of: (Int, [LiveRoom]?).self) { group in
            for (index, site) in sites.enumerated() {
                group.addTask {
                    (index, try? await site.recommendRooms(page: page))
                }
            }
            var collected: [(Int, [LiveRoom]?)] = []
            for await pair in group { collected.append(pair) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let allFailed = perPlatform.allSatisfy { $0 == nil }
        let lists = perPlatform.map { $0 ?? [] }
        return (RoomSearchMerger.mergeInterleaved(lists), allFailed)
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            loadError = nil
            page = 1
        } else {
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        let targetPage = reset ? 1 : page + 1
        let (newRooms, allFailed) = await loadPage(targetPage)
        if reset {
            rooms = newRooms
            page = 1
            canLoadMore = !newRooms.isEmpty
            if newRooms.isEmpty && allFailed {
                loadError = "网络不可用，下拉可重试"
            }
        } else if newRooms.isEmpty {
            if allFailed {
                loadMoreFailed = true
            } else {
                canLoadMore = false
                loadMoreFailed = false
            }
        } else {
            // Dedupe against what is already shown.
            let seen = Set(rooms.map(\.id))
            let fresh = newRooms.filter { !seen.contains($0.id) }
            rooms.append(contentsOf: fresh)
            page = targetPage
            canLoadMore = !fresh.isEmpty
            loadMoreFailed = false
        }
    }

    private func loadMore() async {
        loadMoreFailed = false
        await load(reset: false)
    }
}
