// RoomCard.swift
// HAo Live — shared room card (HAo's own card design):
// 16:9 cover, red LIVE badge, platform chip, viewer count.

import SwiftUI

struct RoomCard: View {
    let room: LiveRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: HaoLiveDesign.cardCornerRadius)
                    .fill(HaoLiveDesign.cardBackground)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "play.tv.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                HStack {
                    Text("LIVE")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(HaoLiveDesign.liveRed, in: Capsule())
                        .foregroundStyle(.white)
                    Spacer()
                    Text(room.viewerCountText)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(8)
            }
            Text(room.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(room.anchorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(room.platform.shortName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: room.platform.colorHex).opacity(0.15), in: Capsule())
                    .foregroundStyle(Color(hex: room.platform.colorHex))
            }
        }
    }
}

/// Two-column room grid used by Favorites / Hot / Categories / Search.
struct RoomGrid: View {
    let rooms: [LiveRoom]
    var onSelect: (LiveRoom) -> Void = { _ in }

    private let columns = [
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
        GridItem(.flexible(), spacing: HaoLiveDesign.gridSpacing),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: HaoLiveDesign.gridSpacing) {
            ForEach(rooms) { room in
                NavigationLink(value: room) {
                    RoomCard(room: room)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
