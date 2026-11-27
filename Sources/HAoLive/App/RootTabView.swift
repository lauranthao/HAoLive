// RootTabView.swift
// HAo Live — main navigation. Four tabs cover Pure Live's functions
// (favorites, hot, categories, history); the layout, tab order
// treatment and cards are HAo's own.

import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var showingSearch = false
    @State private var showingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                FavoritesView()
                    .toolbar { searchButton }
            }
            .tabItem { Label("收藏", systemImage: "heart.fill") }

            NavigationStack {
                HotView()
                    .toolbar { searchButton }
            }
            .tabItem { Label("热门", systemImage: "flame.fill") }

            NavigationStack {
                CategoriesView()
                    .toolbar { searchButton }
            }
            .tabItem { Label("分区", systemImage: "square.grid.2x2.fill") }

            NavigationStack {
                HistoryView()
                    .toolbar { settingsButton }
            }
            .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
        }
        .accentColor(HaoLiveDesign.liveRed)
        .sheet(isPresented: $showingSearch) {
            NavigationStack { SearchView() }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
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

    private var searchButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
        }
    }
}
