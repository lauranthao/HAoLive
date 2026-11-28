// TabReselectHandler.swift
// HAo Live — "tap the selected tab to go home" (HAoMusic's
// popToRoot, which fires from its custom GlassTabBar's onReselect).
// The native TabView exposes no reselect callback, so this bridges
// the UITabBarController delegate: tapping the already-selected
// item calls onReselect with the tab index, and always allows the
// selection. If the system ever installs its own delegate, this
// stands down (no reselect, nothing breaks).

import ObjectiveC
import SwiftUI
import UIKit

final class TabReselectDelegate: NSObject, UITabBarControllerDelegate {
    var onReselect: ((Int) -> Void)?

    func tabBarController(
        _ tabBarController: UITabBarController,
        shouldSelect viewController: UIViewController
    ) -> Bool {
        if tabBarController.selectedViewController === viewController,
           let index = tabBarController.viewControllers?.firstIndex(of: viewController) {
            onReselect?(index)
        }
        return true
    }
}

// Only its address is ever used (objc associated-object key); the
// value is never read or written, so global mutable state is safe.
nonisolated(unsafe) private var tabReselectDelegateKey: UInt8 = 0

/// An invisible view that installs the reselect delegate on the
/// enclosing tab bar controller once it exists in the hierarchy.
struct TabReselectMonitor: UIViewRepresentable {
    var onReselect: (Int) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            TabReselectMonitor.install(on: view, onReselect: onReselect)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { [weak uiView] in
            guard let uiView else { return }
            TabReselectMonitor.install(on: uiView, onReselect: onReselect)
        }
    }

    private static func install(on view: UIView, onReselect: @escaping (Int) -> Void) {
        var responder: UIResponder? = view
        while let current = responder, !(current is UITabBarController) {
            responder = current.next
        }
        guard let tabBar = responder as? UITabBarController else { return }
        if let existing = objc_getAssociatedObject(tabBar, &tabReselectDelegateKey) as? TabReselectDelegate {
            existing.onReselect = onReselect
            return
        }
        guard tabBar.delegate == nil else { return }
        let delegate = TabReselectDelegate()
        delegate.onReselect = onReselect
        tabBar.delegate = delegate
        objc_setAssociatedObject(tabBar, &tabReselectDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
