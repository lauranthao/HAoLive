// ButtonStyles.swift
// HAo Live — press feedback (HAoMusic's DesignSystem/ButtonStyles,
// iOS behaviour only). Cards dim on press, icon buttons shrink +
// fade, chips fill with the accent when selected.

import SwiftUI

/// Cards: press dims to 0.8 (HAoMusic's InteractiveCardStyle on iOS).
struct InteractiveCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Subtle press feedback for icon buttons: shrink to 0.9 + fade to
/// 0.7 (HAoMusic's PressableButtonStyle).
struct PressableButtonStyle: ButtonStyle {
    var pressScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressScale : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(HaoLiveAnimation.quick, value: configuration.isPressed)
    }
}

/// Filter chips (HAoMusic's ChipButtonStyle, kept at Live's sizing:
/// the call sites set the font + padding; the style owns the fill,
/// the selected colour and the press scale).
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(HaoLiveDesign.liveRed)
                        : AnyShapeStyle(Color(.secondarySystemBackground))
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(HaoLiveAnimation.spring, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == InteractiveCardStyle {
    static var interactiveCard: InteractiveCardStyle { InteractiveCardStyle() }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static func chip(isSelected: Bool) -> ChipButtonStyle { ChipButtonStyle(isSelected: isSelected) }
}
