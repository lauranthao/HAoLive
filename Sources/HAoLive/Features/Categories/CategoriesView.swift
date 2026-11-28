// CategoriesView.swift
// HAo Live — browse by platform, then by category.
// Nothing is auto-selected: the user picks a category first.
// Starred categories (my sections) persist; category cards show
// artwork when the platform provides it. Tapping a category pushes
// its own rooms page (CategoryRoomsView) — rooms never load inline
// here.

import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var selectedPlatform: LivePlatform = .bilibili
    @State private var categories: [LiveCategory] = []
    @State private var isLoadingCategories = false
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
                ProgressView().padding(.top, HaoLiveDesign.emptyStateTopPadding)
            } else if categories.isEmpty {
                ContentUnavailableView("分区加载失败", systemImage: "square.grid.2x2", description: Text("下拉重试"))
                    .padding(.top, HaoLiveDesign.emptyStateTopPadding)
            } else if filteredCategories.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .padding(.top, HaoLiveDesign.emptyStateTopPadding)
            } else {
                LazyVGrid(columns: columns, spacing: HaoLiveDesign.gridSpacing) {
                    ForEach(filteredCategories) { category in
                        NavigationLink(value: category) {
                            CategoryCard(
                                category: category,
                                starred: settingsStore.favoriteCategoryIDs.contains(category.id),
                                onToggleStar: { toggleStar(category) }
                            )
                        }
                        .buttonStyle(.interactiveCard)
                    }
                }
                .padding(HaoLiveDesign.pagePadding)
            }
        }
        .refreshable { await reload() }
        .navigationTitle("分区")
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .navigationDestination(for: LiveCategory.self) { category in
            CategoryRoomsView(category: category)
        }
        .task(id: selectedPlatform) { await loadCategories() }
    }

    // MARK: - Sections

    private var platformRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LivePlatform.allCases, id: \.self) { platform in
                    Button {
                        selectedPlatform = platform
                    } label: {
                        HStack(spacing: 6) {
                            PlatformLogo(platform: platform, size: 18)
                            Text(platform.shortName)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, HaoLiveDesign.chipHorizontalPadding)
                        .padding(.vertical, HaoLiveDesign.chipVerticalPadding)
                        .background(selectedPlatform == platform ? Color(hex: platform.colorHex).opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(selectedPlatform == platform ? Color(hex: platform.colorHex) : .primary)
                    }
                    .buttonStyle(.pressable)
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: HaoLiveDesign.controlCornerRadius))
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
                        NavigationLink(value: category) {
                            Text(category.name)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, HaoLiveDesign.chipHorizontalPadding)
                                .padding(.vertical, HaoLiveDesign.chipVerticalPadding)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, HaoLiveDesign.pagePadding)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

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
    }

    private func loadCategories() async {
        guard let site = SiteRegistry.site(for: selectedPlatform) else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        if let list = try? await site.categories() {
            categories = list
        }
    }
}

/// One category card: artwork when available, name, star toggle.
/// Wrapped in a NavigationLink by the parent — tapping pushes the
/// category's own rooms page.
private struct CategoryCard: View {
    let category: LiveCategory
    let starred: Bool
    let onToggleStar: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CategoryIcon(url: category.iconURL, name: category.name, platform: category.platform)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: HaoLiveDesign.controlCornerRadius))
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: HaoLiveDesign.cardCornerRadius))
    }
}

/// Category artwork via the shared cover cache (per-host Referer);
/// a first-letter tile in the platform colour when the platform
/// provides no artwork.
private struct CategoryIcon: View {
    let url: URL?
    let name: String
    let platform: LivePlatform

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HaoLiveDesign.controlCornerRadius)
                .fill(Color(hex: platform.colorHex))
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
