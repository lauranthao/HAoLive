// DanmakuOverlayView.swift
// HAo Live — danmaku overlay: real scrolling lanes over the player.
// FlameBarrage-style lanes (Pure Live's renderer), simplified for
// SwiftUI: lane count comes from the display area and font size,
// a message takes the least-busy lane, and a new message on a lane
// waits until the previous one has cleared its width + a gap, so
// messages never overtake each other on the same lane.

import SwiftUI

struct DanmakuOverlayView: View {
    let items: [DanmakuItem]
    var fontSize: Double
    var opacity: Double
    var speed: Double = 120
    var area: Double = 1.0
    var fontWeight: Int = 500
    var letterSpacing: Double = 0
    var strokeEnabled: Bool = true
    var strokeWidth: Double = 1.5
    var maxVisibleCount: Int = 48

    @State private var active: [LaneItem] = []
    @State private var seenIDs: Set<String> = []

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let trackHeight = max(24, min(64, fontSize * 1.55))
            let laneCount = max(1, Int(size.height * area / trackHeight))
            ZStack(alignment: .topLeading) {
                ForEach(active) { laneItem in
                    DanmakuLaneRow(
                        laneItem: laneItem,
                        containerWidth: size.width,
                        fontSize: fontSize,
                        opacity: opacity,
                        fontWeight: fontWeight,
                        letterSpacing: letterSpacing,
                        strokeEnabled: strokeEnabled,
                        strokeWidth: strokeWidth
                    )
                    .offset(y: CGFloat(laneItem.lane) * trackHeight)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
            .onChange(of: items) { _, newItems in
                feed(newItems: newItems, containerWidth: size.width, trackHeight: trackHeight, laneCount: laneCount)
            }
        }
        .allowsHitTesting(false)
    }

    private func feed(newItems: [DanmakuItem], containerWidth: CGFloat, trackHeight: CGFloat, laneCount: Int) {
        // A fresh (empty) list means the room changed: reset.
        if newItems.isEmpty {
            active = []
            seenIDs = []
            return
        }
        let fresh = newItems.filter { seenIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        for item in fresh {
            guard active.count < maxVisibleCount else { return }
            let textWidth = estimatedWidth(for: item)
            // Least-busy lane wins; a new message waits until the
            // lane's last message has cleared its width + a gap.
            let lane = (0..<laneCount).min { a, b in
                active.filter { $0.lane == a }.count < active.filter { $0.lane == b }.count
            } ?? 0
            let lastOnLane = active.filter { $0.lane == lane }.last
            let wait = lastOnLane.map { ($0.textWidth + 60) / speed } ?? 0
            let duration = (containerWidth + textWidth + 40) / speed
            let laneItem = LaneItem(id: item.id, lane: lane, item: item, textWidth: textWidth, duration: duration)
            if wait > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    active.append(laneItem)
                    Task {
                        try? await Task.sleep(for: .seconds(duration))
                        active.removeAll { $0.id == laneItem.id }
                    }
                }
            } else {
                active.append(laneItem)
                Task {
                    try? await Task.sleep(for: .seconds(duration))
                    active.removeAll { $0.id == laneItem.id }
                }
            }
        }
    }

    /// Rough CJK width: one full-width glyph per character at the
    /// font size. Overestimating only adds spacing between messages.
    private func estimatedWidth(for item: DanmakuItem) -> CGFloat {
        CGFloat(item.user.count + 1 + item.text.count) * fontSize
    }
}

/// One scrolling message: starts off the right edge, moves left at
/// a constant speed, and is removed by the parent when done.
private struct DanmakuLaneRow: View {
    let laneItem: LaneItem
    let containerWidth: CGFloat
    let fontSize: Double
    let opacity: Double
    let fontWeight: Int
    let letterSpacing: Double
    let strokeEnabled: Bool
    let strokeWidth: Double

    @State private var x: CGFloat?

    var body: some View {
        Text("\(laneItem.item.user) \(laneItem.item.text)")
            .font(.system(size: fontSize, weight: Self.weight(for: fontWeight)))
            .tracking(letterSpacing)
            .foregroundStyle(.white.opacity(opacity))
            .shadow(color: strokeEnabled ? .black.opacity(0.85) : .clear, radius: strokeWidth)
            .offset(x: x ?? containerWidth)
            .onAppear {
                x = containerWidth
                withAnimation(.linear(duration: laneItem.duration)) {
                    x = -(laneItem.textWidth + 40)
                }
            }
    }

    private static func weight(for value: Int) -> Font.Weight {
        switch value {
        case ..<200: .ultraLight
        case ..<300: .thin
        case ..<400: .light
        case ..<500: .regular
        case ..<600: .medium
        case ..<700: .semibold
        case ..<800: .bold
        case ..<900: .heavy
        default: .black
        }
    }
}

/// One message on one lane: which lane, how wide it is, how long
/// the crossing takes.
private struct LaneItem: Identifiable {
    var id: String
    var lane: Int
    var item: DanmakuItem
    var textWidth: CGFloat
    var duration: Double
}
