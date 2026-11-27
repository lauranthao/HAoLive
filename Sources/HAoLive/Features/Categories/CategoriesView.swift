// CategoriesView.swift
// HAo Live — browse by platform, then by category.
// Nothing is auto-selected: the user picks a category first.
// Starred categories (my sections) persist; category cards show
// artwork when the platform provides it; rooms page with load-more.

import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var selectedPlatform: LivePlatform = .bilibili
    @State private var categories: [LiveCategory] = []
    @State private var selectedCategory: LiveCategory?
    @State private var rooms: [LiveRoom] = []
    @State private var page = 1
    @State private var canLoadMore = false
    @State private var isLoadingCategories = false
    @State private var isLoadingRooms = false
    @State private var isLoadingMore = false
    @State private var roomsError: String?
    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
    ]

    private var filteredCategories: [LiveCategory] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return categories }
        return categories.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Starred categories of the current platform, in list order.
    private var starredCategories: [LiveCategory] {
        categories.filter { settingsStore.favoriteCategoryIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            platformRail
            searchField
            if !starredCategories.isEmpty {
                starredSection
            }
            if isLoadingCategories {
                ProgressView().padding(.top, 40)
            } else if categories.isEmpty {
                ContentUnavailableView("分区加载失败", systemImage: "square.grid.2x2", description: Text("下拉重试"))
                    .padding(.top, 40)
            } else if filteredCategories.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: HaoLiveDesign.gridSpacing) {
                    ForEach(filteredCategories) { category in
                        CategoryCard(
                            category: category,
                            selected: selectedCategory?.id == category.id,
                            starred: settingsStore.favoriteCategoryIDs.contains(category.id),
                            onSelect: { select(category) },
                            onToggleStar: { toggleStar(category) }
                        )
                    }
                }
                .padding(.horizontal, HaoLiveDesign.pagePadding)
                .padding(.vertical, 8)
            }
            if let category = selectedCategory {
                roomsSection(for: category)
            }
        }
        .refreshable { await reload() }
        .navigationTitle("分区")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .task(id: selectedPlatform) { await loadCategories() }
        .task(id: selectedCategory) { await loadRooms(reset: true) }
    }

    // MARK: - Sections

    private var platformRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LivePlatform.allCases, id: \.self) { platform in
                    Button {
                        selectedPlatform = platform
                        selectedCategory = nil
                        rooms = []
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

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜分区", text: $searchText)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.bottom, 4)
    }

    private var starredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的分区")
                .font(.subheadline.bold())
                .padding(.horizontal, HaoLiveDesign.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(starredCategories) { category in
                        Button(category.name) { select(category) }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedCategory?.id == category.id ? HaoLiveDesign.liveRed : Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(selectedCategory?.id == category.id ? .white : .primary)
                    }
                }
                .padding(.horizontal, HaoLiveDesign.pagePadding)
            }
        }
        .padding(.vertical, 4)
    }

    private func roomsSection(for category: LiveCategory) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(category.name)
                    .font(.headline)
                Spacer()
                if let error = roomsError, rooms.isEmpty {
                    Button("重试") { Task { await loadRooms(reset: true) } }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .padding(.vertical, 8)
            if isLoadingRooms {
                ProgressView().padding(.top, 40)
            } else if let error = roomsError, rooms.isEmpty {
                ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(error))
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
    }

    // MARK: - Actions

    private func select(_ category: LiveCategory) {
        selectedCategory = category
    }

    private func toggleStar(_ category: LiveCategory) {
        var ids = settingsStore.favoriteCategoryIDs
        if ids.contains(category.id) {
            ids.removeAll { $0 == category.id }
        } else {
            ids.append(category.id)
        }
        settingsStore.favoriteCategoryIDs = ids
    }

    private func reload() async {
        await loadCategories()
        if selectedCategory != nil {
            await loadRooms(reset: true)
        }
    }

    private func loadCategories() async {
        guard let site = SiteRegistry.site(for: selectedPlatform) else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        if let list = try? await site.categories() {
            categories = list
            // Keep the selection only if it still exists; never
            // force-select the first category.
            if let selected = selectedCategory, !list.contains(selected) {
                selectedCategory = nil
                rooms = []
            }
        }
    }

    private func loadRooms(reset: Bool) async {
        guard let site = SiteRegistry.site(for: selectedPlatform),
              let category = selectedCategory else { return }
        if reset {
            isLoadingRooms = true
            roomsError = nil
            page = 1
        } else {
            isLoadingMore = true
        }
        defer {
            isLoadingRooms = false
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

/// One category card: artwork when available, name, star toggle.
private struct CategoryCard: View {
    let category: LiveCategory
    let selected: Bool
    let starred: Bool
    let onSelect: () -> Void
    let onToggleStar: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CategoryIcon(url: category.iconURL, name: category.name)
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button(action: onToggleStar) {
                        Image(systemName: starred ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(starred ? .yellow : .white)
                            .padding(6)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
                Text(category.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(8)
            .background(selected ? HaoLiveDesign.liveRed.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: HaoLiveDesign.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: HaoLiveDesign.cardCornerRadius)
                    .stroke(selected ? HaoLiveDesign.liveRed : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Category artwork via the shared cover cache (per-host Referer);
/// a first-letter tile when the platform provides no artwork.
private struct CategoryIcon: View {
    let url: URL?
    let name: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "#3A3A3C").opacity(0.35))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(name.prefix(1)))
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await CoverImageCache.shared.image(for: url)
        }
    }
}
