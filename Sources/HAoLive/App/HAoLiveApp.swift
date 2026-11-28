// HAoLiveApp.swift
// HAo Live — app entry. No launch animation: straight to the main screen.

import SwiftUI
import UIKit

/// Orientation gate: the app is portrait everywhere; only the live
/// room's fullscreen player takes it to landscape. Rotating the phone
/// never changes orientation on its own, and landscape works with the
/// system orientation lock ON because the AppDelegate below overrides
/// the supported orientations for the window.
final class OrientationLock {
    // Only ever touched from the main thread (SwiftUI lifecycle +
    // AppDelegate), so the shared instance needs no isolation.
    nonisolated(unsafe) static let shared = OrientationLock()

    private(set) var supportedOrientations: UIInterfaceOrientationMask = .portrait

    private init() {}

    func lockPortrait() {
        supportedOrientations = .portrait
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }

    func lockLandscape() {
        supportedOrientations = .landscape
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.supportedOrientations
    }
}

@main
struct HAoLiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favoritesStore = FavoritesStore()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(favoritesStore)
                .environmentObject(historyStore)
                .environmentObject(settingsStore)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    // Pure Live applies a separate cellular default
                    // quality; the monitor must be running before
                    // any room opens.
                    NetworkTypeMonitor.shared.start()
                }
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
