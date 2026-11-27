// RoomCard.swift
// HAo Live — shared room card (HAo's own card design):
// 16:9 cover, red LIVE badge, platform chip, viewer count.
// Covers load for real (cached, per-host Referer like Pure Live's
// networkImageHeaders); the gray placeholder + play icon stays while
// loading and when a cover fails to load.

import SwiftUI
import UIKit

/// Cached cover loader. Some image CDNs refuse bare requests, so the
/// request carries the platform's Referer (Pure Live does the same
/// for its room cards).
final class CoverImageCache {
    static let shared = CoverImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let session = URLSession.shared

    private init() {
        cache.countLimit = 200
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.referer(for: url), forHTTPHeaderField: "Referer")
        request.setValue(HTTPClient.shared.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func referer(for url: URL) -> String {
        guard let host = url.host else { return "https://live.bilibili.com/" }
        if host.contains("hdslb.com") || host.contains("bilibili.com") { return "https://live.bilibili.com/" }
        if host.contains("douyin") { return "https://live.douyin.com/" }
        if host.contains("kuaishou") || host.contains("yximgs.com") || host.contains("gifshow.com") { return "https://live.kuaishou.com/" }
        if host.contains("huya.com") { return "https://www.huya.com/" }
        if host.contains("douyu") { return "https://www.douyu.com/" }
        return "https://live.bilibili.com/"
    }
}

/// A room cover that loads from the network; the placeholder shows
/// while loading and when there is no cover or the load fails.
struct CoverImage: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HaoLiveDesign.cardCornerRadius)
                .fill(HaoLiveDesign.cardBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: HaoLiveDesign.cardCornerRadius))
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await CoverImageCache.shared.image(for: url)
        }
    }
}

struct RoomCard: View {
    let room: LiveRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CoverImage(url: room.coverURL)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
