// RootTabView.swift
// HAo Live — main navigation. Five tabs (HAoMusic's shape: search
// is a tab, not a toolbar button). Every tab keeps its own
// navigation path, and tapping the already-selected tab pops it to
// its root (HAoMusic's popToRoot). Settings stays a sheet, with a
// Done button like HAoMusic's SettingsSheet.

import SwiftUI

private enum LiveTab: Hashable {
    case favorites, hot, categories, search, history
}

struct RootTabView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var toasts = ToastCenter.shared

    @State private var selectedTab: LiveTab = .favorites
    @State private var favoritesPath = NavigationPath()
    @State private var hotPath = NavigationPath()
    @State private var categoriesPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var showingSettings = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $favoritesPath) {
                FavoritesView()
            }
            .tabItem { Label("收藏", systemImage: "heart.fill") }
            .tag(LiveTab.favorites)

            NavigationStack(path: $hotPath) {
                HotView()
            }
            .tabItem { Label("热门", systemImage: "flame.fill") }
            .tag(LiveTab.hot)

            NavigationStack(path: $categoriesPath) {
                CategoriesView()
            }
            .tabItem { Label("分区", systemImage: "square.grid.2x2.fill") }
            .tag(LiveTab.categories)

            NavigationStack(path: $searchPath) {
                SearchView()
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(LiveTab.search)

            NavigationStack(path: $historyPath) {
                HistoryView()
                    .toolbar { settingsButton }
            }
            .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            .tag(LiveTab.history)
        }
        .accentColor(HaoLiveDesign.liveRed)
        .background(TabReselectMonitor { index in popToRoot(index: index) })
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingSettings = false }
                        }
                    }
            }
        }
        // HAoMusic's top toast overlay (same spot, same animation).
        .overlay(alignment: .top) {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toasts.current)
        .environmentObject(toasts)
    }

    /// HAoMusic's popToRoot: tapping the selected tab clears that
    /// tab's navigation path.
    private func popToRoot(index: Int) {
        switch index {
        case 0: favoritesPath = NavigationPath()
        case 1: hotPath = NavigationPath()
        case 2: categoriesPath = NavigationPath()
        case 3: searchPath = NavigationPath()
        case 4: historyPath = NavigationPath()
        default: break
        }
    }

    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
        }
    }
}
