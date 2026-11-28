// ToastCenter.swift
// HAo Live — top toast (HAoMusic's ToastCenter + ToastView, same
// behaviour: slide in from the top + fade, spring 0.3, auto-dismiss
// after 3 s). Used where an action otherwise has no feedback:
// favorite toggles, copy link, clear cache, clear history.

import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String) {
        current = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }
}

/// The toast pill (HAoMusic's ToastView: 12.5 pt medium text,
/// 16/9 padding, rounded 10, soft shadow; glass via system material).
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
