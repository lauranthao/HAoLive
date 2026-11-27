// SearchView.swift
// HAo Live — cross-platform search (HAo's own layer):
// one keyword searches all selected platforms in parallel.
// Two result kinds (rooms / anchors — every platform implements
// searchAnchors), per-platform filter, sorting, pagination, and a
// web-search fallback that opens the platform's own search page
// in the browser (Kuaishou has no native search API at all, so
// its web search is the only fallback there).

import SwiftUI

enum LiveSearchSort: String, CaseIterable {
    case smart = "智能"
    case platform = "平台"
    case audience = "人气"

    /// Pure Live's sort modes, simplified: smart = live first, then
    /// audience, then platform order; platform = platform order,
    /// then audience; audience = viewers first.
    func sort(_ rooms: [LiveRoom]) -> [LiveRoom] {
        let platformOrder = LivePlatform.allCases
        switch self {
        case .smart:
            return rooms.sorted {
                if $0.isLive != $1.isLive { return $0.isLive }
                if $0.viewerCount != $1.viewerCount { return $0.viewerCount > $1.viewerCount }
                return platformOrder.firstIndex(of: $0.platform) ?? 99 < platformOrder.firstIndex(of: $1.platform) ?? 99
            }
        case .platform:
            return rooms.sorted {
                let a = platformOrder.firstIndex(of: $0.platform) ?? 99
                let b = platformOrder.firstIndex(of: $1.platform) ?? 99
                if a != b { return a < b }
                return $0.viewerCount > $1.viewerCount
            }
        case .audience:
            return rooms.sorted { $0.viewerCount > $1.viewerCount }
        }
    }
}

struct SearchView: View {
    @State private var keyword = ""
    @State private var results: [LiveRoom] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var page = 1
    @State private var canLoadMore = false
    @State private var isLoadingMore = false
    @State private var searchFailed = false
    @State private var kind: SearchKind = .rooms
    @State private var selectedPlatform: LivePlatform?
    @State private var sort: LiveSearchSort = .smart
    @State private var includeOffline = true
    /// Generation counter: a slow earlier search must never
    /// overwrite a newer one's results.
    @State private var searchGeneration = 0

    @Environment(\.dismiss) private var dismiss

    private enum SearchKind: String, CaseIterable {
        case rooms = "房间"
        case anchors = "主播"
    }

    private var visibleResults: [LiveRoom] {
        var list = includeOffline ? results : results.filter(\.isLive)
        return sort.sort(list)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            kindPicker
            platformChips
            sortRow
            if isSearching {
                ProgressView().padding(.top, 60)
            } else if didSearch && results.isEmpty {
                emptyState
            } else if didSearch {
                resultsList
            } else {
                ContentUnavailableView(
                    "跨平台搜索",
                    systemImage: "magnifyingglass",
                    description: Text("一次搜遍哔哩哔哩、斗鱼、虎牙、抖音、快手")
                )
                .padding(.top, 40)
            }
            Spacer()
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    // MARK: - Header controls

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜房间、搜主播", text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await search(reset: true) } }
                .onChange(of: keyword) { _, newValue in
                    // 300ms debounce: type, pause, then search.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard newValue == keyword, !newValue.isEmpty else { return }
                        await search(reset: true)
                    }
                }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    results = []
                    didSearch = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.top, 4)
    }

    private var kindPicker: some View {
        Picker("类型", selection: $kind) {
            ForEach(SearchKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.top, 8)
        .onChange(of: kind) { Task { await search(reset: true) } }
    }

    private var platformChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", selected: selectedPlatform == nil) {
                    selectedPlatform = nil
                    Task { await search(reset: true) }
                }
                ForEach(LivePlatform.allCases, id: \.self) { platform in
                    chip(title: platform.shortName, selected: selectedPlatform == platform) {
                        selectedPlatform = platform
                        Task { await search(reset: true) }
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

    private var sortRow: some View {
        HStack {
            Picker("排序", selection: $sort) {
                ForEach(LiveSearchSort.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Toggle("含离线", isOn: $includeOffline)
                .font(.subheadline)
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.bottom, 4)
    }

    // MARK: - Results

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView.search(text: keyword)
                .padding(.top, 40)
            if searchFailed {
                Text("各平台搜索都失败了，检查网络后重试")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let url = webSearchURL {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("在网页中搜索", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            }
            if searchFailed {
                Button("重试") { Task { await search(reset: true) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var resultsList: some View {
        List {
            ForEach(visibleResults) { room in
                NavigationLink(value: room) {
                    if kind == .rooms {
                        RoomCard(room: room)
                    } else {
                        AnchorRow(room: room)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            if canLoadMore {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView()
                    } else {
                        Button("加载更多") { Task { await search(reset: false) } }
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    /// The selected platform's own web search page (all five URLs
    /// verified live 2026-11-27). Kuaishou has no native search,
    /// so this is its only search fallback.
    private var webSearchURL: URL? {
        let encoded = keyword.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        switch selectedPlatform ?? .bilibili {
        case .bilibili:
            return URL(string: "https://search.bilibili.com/live?keyword=\(encoded)")
        case .douyu:
            return URL(string: "https://www.douyu.com/search/?kw=\(encoded)")
        case .huya:
            return URL(string: "https://search.huya.com/?search=\(encoded)")
        case .douyin:
            return URL(string: "https://www.douyin.com/search/\(encoded)")
        case .kuaishou:
            return URL(string: "https://www.kuaishou.com/search/video?searchKey=\(encoded)")
        }
    }

    // MARK: - Search

    private func sites() -> [any LiveSite] {
        if let selectedPlatform, let site = SiteRegistry.site(for: selectedPlatform) {
            return [site]
        }
        return SiteRegistry.sites
    }

    private func search(reset: Bool) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if reset {
            searchGeneration += 1
            isSearching = true
            searchFailed = false
            page = 1
        }
        let generation = searchGeneration
        if !reset {
            isLoadingMore = true
        }
        defer {
            isSearching = false
            isLoadingMore = false
        }
        let targetPage = reset ? 1 : page + 1
        let sites = sites()
        let perPlatform = await withTaskGroup(of: (Int, [LiveRoom]?).self) { group in
            for (index, site) in sites.enumerated() {
                group.addTask {
                    let list: [LiveRoom]?
                    switch kind {
                    case .rooms:
                        list = try? await site.searchRooms(keyword: trimmed, page: targetPage)
                    case .anchors:
                        list = try? await site.searchAnchors(keyword: trimmed, page: targetPage)
                    }
                    return (index, list)
                }
            }
            var collected: [(Int, [LiveRoom]?)] = []
            for await pair in group { collected.append(pair) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // A newer search started while this one was in flight:
        // drop its results.
        guard generation == searchGeneration else { return }
        let allFailed = perPlatform.allSatisfy { $0 == nil }
        let merged = RoomSearchMerger.merge(perPlatform.map { $0 ?? [] })
        if reset {
            results = merged
            page = 1
            canLoadMore = !merged.isEmpty
            didSearch = true
            searchFailed = merged.isEmpty && allFailed
        } else if merged.isEmpty {
            canLoadMore = !allFailed
        } else {
            let seen = Set(results.map(\.id))
            results.append(contentsOf: merged.filter { !seen.contains($0.id) })
            page = targetPage
            canLoadMore = true
        }
    }
}

/// One anchor result: avatar, name, category, live state.
private struct AnchorRow: View {
    let room: LiveRoom

    var body: some View {
        HStack(spacing: 12) {
            if let avatarURL = room.anchorAvatarURL {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.3)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 44, height: 44)
                    .overlay(Text(String(room.anchorName.prefix(1))).font(.headline))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(room.anchorName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(room.categoryName ?? room.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(room.platform.displayName)
                    .font(.caption2)
                    .foregroundStyle(Color(hex: room.platform.colorHex))
            }
            Spacer()
            if room.isLive {
                Text("LIVE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(HaoLiveDesign.liveRed, in: Capsule())
                    .foregroundStyle(.white)
            } else {
                Text("离线")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
