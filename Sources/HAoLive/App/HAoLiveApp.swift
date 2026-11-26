// HAoLiveApp.swift
// HAo Live — app entry. No launch animation: straight to the main screen.

import SwiftUI

@main
struct HAoLiveApp: App {
    @StateObject private var favoritesStore = FavoritesStore()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var recorder = LiveRecorder()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(favoritesStore)
                .environmentObject(historyStore)
                .environmentObject(settingsStore)
                .environmentObject(recorder)
                .environmentObject(recorder.store)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch settingsStore.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
