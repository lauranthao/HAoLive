// FavoritesView.swift
// HAo Live — followed rooms. Local only; no account.
//
// Favorites are live, not snapshots: opening the page re-checks
// each room (title / viewers / live status) in parallel. Three
// status tabs (all / online / offline, Pure Live's shape minus
// the replay tab — there is no recording), a platform rail with
// only platforms that have saved rooms, tag filters, and sorting.

import SwiftUI

enum FavoriteSort: String, CaseIterable {
    case recent = "最近收藏"
    case audience = "人气"
    case name = "名称"
    case platform = "平台"

    func sort(_ entries: [FavoriteEntry]) -> [FavoriteEntry] {
        switch self {
        case .recent:
            return entries.sorted { $0.addedAt > $1.addedAt }
        case .audience:
            return entries.sorted { $0.room.viewerCount > $1.room.viewerCount }
        case .name:
            return entries.sorted { $0.room.anchorName < $1.room.anchorName }
        case .platform:
            let order = LivePlatform.allCases
            return entries.sorted {
                (order.firstIndex(of: $0.room.platform) ?? 99) < (order.firstIndex(of: $1.room.platform) ?? 99)
            }
        }
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore

    @State private var statusTab = 0 // 0 全部, 1 在线, 2 离线
    @State private var platformFilter: LivePlatform?
    @State private var selectedTag: String?
    @State private var sort: FavoriteSort = .recent
    @State private var visibleCount = 30
    @State private var isRefreshing = false
    @State private var tagEditingRoom: LiveRoom?

    private let pageSize = 30
    private let columns = [
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
    ]

    /// Platforms that actually have saved rooms (rail only shows these).
    private var presentPlatforms: [LivePlatform] {
        let set = Set(favoritesStore.entries.map(\.room.platform))
        return LivePlatform.allCases.filter { set.contains($0) }
    }

    private var filteredEntries: [FavoriteEntry] {
        var list = favoritesStore.entries
        switch statusTab {
        case 1: list = list.filter(\.room.isLive)
        case 2: list = list.filter { !$0.room.isLive }
        default: break
        }
        if let platformFilter {
            list = list.filter { $0.room.platform == platformFilter }
        }
        if let selectedTag {
            list = list.filter { $0.tags.contains(selectedTag) }
        }
        return sort.sort(list)
    }

    private var onlineCount: Int {
        favoritesStore.entries.filter(\.room.isLive).count
    }

    var body: some View {
        ScrollView {
            // NOTE: a ScrollView's implicit VStack is center-aligned,
            // so every fixed-width child (status chips row, status
            // text) was rendered centered while full-width children
            // looked left-aligned. Explicit leading alignment fixes it.
            VStack(alignment: .leading, spacing: 0) {
                if favoritesStore.entries.isEmpty {
                ContentUnavailableView(
                    "还没有收藏的房间",
                    systemImage: "heart",
                    description: Text("在直播间点收藏，房间会出现在这里")
                )
                .padding(.top, HaoLiveDesign.emptyStateTopPadding)
            } else {
                statusTabs
                platformRail
                tagRow
                sortRow
                if isRefreshing {
                    ProgressView("正在更新直播状态…")
                        .padding(.vertical, 8)
                } else if let last = favoritesStore.lastRefreshAt {
                    Text("直播状态更新于 \(last, style: .relative)前")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HaoLiveDesign.pagePadding)
                        .padding(.vertical, 4)
                }
                LazyVGrid(columns: columns, spacing: HaoLiveDesign.gridSpacing) {
                    ForEach(Array(filteredEntries.prefix(visibleCount))) { entry in
                        NavigationLink(value: entry.room) {
                            RoomCard(room: entry.room)
                        }
                        .buttonStyle(.interactiveCard)
                        .contextMenu {
                            Button("编辑标签") { tagEditingRoom = entry.room }
                            Button("取消收藏", role: .destructive) {
                                favoritesStore.remove(entry.room)
                                ToastCenter.shared.show("已取消收藏")
                            }
                        }
                    }
                }
                .padding(HaoLiveDesign.pagePadding)
                if filteredEntries.count > visibleCount {
                    Button("加载更多") { visibleCount += pageSize }
                        .font(.subheadline)
                        .padding(.vertical, 16)
                }
                if filteredEntries.isEmpty {
                    ContentUnavailableView("没有符合条件的收藏", systemImage: "heart.slash")
                        .padding(.top, HaoLiveDesign.emptyStateTopPadding)
                }
            }
            }
        }
        .refreshable {
            await refresh()
        }
        .navigationTitle("收藏")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .task { await refresh() }
        .sheet(item: $tagEditingRoom) { room in
            TagEditorSheet(
                room: room,
                tags: favoritesStore.tags(for: room)
            ) { tags in
                favoritesStore.setTags(tags, for: room)
            }
        }
    }

    // MARK: - Filters

    private var statusTabs: some View {
        HStack(spacing: 8) {
            statusChip(title: "全部 (\(favoritesStore.entries.count))", selected: statusTab == 0) { statusTab = 0 }
            statusChip(title: "在线 (\(onlineCount))", selected: statusTab == 1) { statusTab = 1 }
            statusChip(title: "离线 (\(favoritesStore.entries.count - onlineCount))", selected: statusTab == 2) { statusTab = 2 }
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.top, 8)
    }

    private func statusChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.chip(isSelected: selected))
    }

    private var platformRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部平台", selected: platformFilter == nil) {
                    platformFilter = nil
                }
                ForEach(presentPlatforms, id: \.self) { platform in
                    chip(title: platform.shortName, selected: platformFilter == platform) {
                        platformFilter = platform
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
                .padding(.horizontal, HaoLiveDesign.chipHorizontalPadding)
                .padding(.vertical, HaoLiveDesign.chipVerticalPadding)
        }
        .buttonStyle(.chip(isSelected: selected))
    }

    private var tagRow: some View {
        Group {
            if !favoritesStore.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(title: "全部标签", selected: selectedTag == nil) {
                            selectedTag = nil
                        }
                        ForEach(favoritesStore.allTags, id: \.self) { tag in
                            chip(title: "#\(tag)", selected: selectedTag == tag) {
                                selectedTag = tag
                            }
                        }
                    }
                    .padding(.horizontal, HaoLiveDesign.pagePadding)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var sortRow: some View {
        HStack {
            Text("排序")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("排序", selection: $sort) {
                ForEach(FavoriteSort.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.bottom, 4)
    }

    private func refresh() async {
        guard !favoritesStore.entries.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await favoritesStore.refreshStatuses()
    }
}

/// Edit a favorite's tags (comma-separated). Tags are the user's own
/// grouping — Pure Live's LiveTag, without a separate tag manager.
private struct TagEditorSheet: View {
    let room: LiveRoom
    var tags: [String]
    var onSave: ([String]) -> Void

    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("标签（用逗号分隔）") {
                    TextField("例如：游戏, 唱歌", text: $text)
                }
                Section {
                    Text("给收藏的房间打标签，方便按标签筛选。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let tags = text.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave(tags)
                        dismiss()
                    }
                }
            }
            .onAppear { text = tags.joined(separator: ", ") }
        }
    }
}
