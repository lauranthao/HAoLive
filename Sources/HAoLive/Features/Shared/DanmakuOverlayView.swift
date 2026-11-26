// DanmakuOverlayView.swift
// HAo Live — danmaku overlay: recent messages as floating pills
// over the player. Style and layout are HAo's own.

import SwiftUI

struct DanmakuOverlayView: View {
    let items: [DanmakuItem]
    var fontSize: Double
    var opacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Text(item.user)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(item.text)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45 * opacity), in: Capsule())
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .allowsHitTesting(false)
    }
}
