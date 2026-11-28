// RoomCard.swift
// HAo Live — shared room card (HAo's own card design):
// 16:9 cover, red LIVE badge, platform chip, viewer count.
// Covers load for real (cached, per-host Referer like Pure Live's
// networkImageHeaders); the gray placeholder + play icon stays while
// loading and when a cover fails to load.

import SwiftUI
import UIKit
import os

/// Cached cover loader. Some image CDNs refuse bare requests, so the
/// request carries the platform's Referer (Pure Live does the same
/// for its room cards).
final class CoverImageCache {
    // NSCache and URLSession are both thread-safe; the cache holds no
    // other mutable state, so the shared instance needs no isolation.
    nonisolated(unsafe) static let shared = CoverImageCache()

    private static let logger = Logger(subsystem: "live.haostudio", category: "cover")

    private let cache = NSCache<NSString, UIImage>()
    /// Disk cache for covers: memory alone re-downloads everything
    /// on every cold start and page turn.
    private static let urlCache = URLCache(
        memoryCapacity: 20 * 1024 * 1024,
        diskCapacity: 200 * 1024 * 1024,
        diskPath: "hao-live-covers"
    )
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        return URLSession(configuration: config)
    }()

    private init() {
        cache.countLimit = 200
    }

    /// Loads a cover: memory cache, then network with up to 2
    /// retries (short backoff). A non-2xx response counts as a
    /// failure — an error page must never be treated as an image.
    /// Failures are logged (the old `try?` swallowed them, so a
    /// dead cover stayed blank forever with no trace).
    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var lastError: (any Error)?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue(Self.referer(for: url), forHTTPHeaderField: "Referer")
                request.setValue(HTTPClient.shared.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw LiveSiteError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard let image = UIImage(data: data) else {
                    throw LiveSiteError.invalidResponse
                }
                cache.setObject(image, forKey: key)
                return image
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
                }
            }
        }
        Self.logger.warning("cover load failed: \(url.absoluteString, privacy: .public) \(String(describing: lastError), privacy: .public)")
        return nil
    }

    /// Clear the in-memory cover cache and the shared URL cache.
    /// Favorites and history are untouched (they are user data,
    /// not cache).
    func clear() {
        cache.removeAllObjects()
        Self.urlCache.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
    }

    private static func referer(for url: URL) -> String {
        guard let host = url.host else { return "https://live.bilibili.com/" }
        if host.contains("hdslb.com") || host.contains("bilibili.com") { return "https://live.bilibili.com/" }
        if host.contains("douyin") { return "https://live.douyin.com/" }
        if host.contains("kuaishou") || host.contains("yximgs.com") || host.contains("gifshow.com") { return "https://live.kuaishou.com/" }
        if host.contains("msstatic.com") || host.contains("huya.com") { return "https://www.huya.com/" }
        if host.contains("douyu") { return "https://www.douyu.com/" }
        if host.contains("17app.co") || host.contains("17app.akamaized.net") { return "https://17.live/" }
        if host.contains("pstatic.net") || host.contains("akamaized.net") || host.contains("naver.com") { return "https://chzzk.naver.com/" }
        if host.contains("360buyimg.com") || host.contains("jd.com") { return "https://lives.jd.com/" }
        // Build 12: the three audited platforms had no mapping and
        // fell through to the bilibili default. TikTok's CDN,
        // YouTube's image hosts and Twitch's CDN get their own
        // site as Referer (the platform's own pages send the same).
        if host.contains("tiktokcdn") || host.contains("tiktokv.com") || host.contains("byteoversea.com") { return "https://www.tiktok.com/" }
        if host.contains("ytimg.com") || host.contains("ggpht.com") || host.contains("googleusercontent.com") { return "https://www.youtube.com/" }
        if host.contains("jtvnw.net") || host.contains("twitch.tv") { return "https://www.twitch.tv/" }
        // Bigo's covers live on esx.bigo.sg and are hot-linked
        // from bigo.tv pages; LiveMe's on esx.esxscloud.com and
        // are hot-linked from liveme.com/livehot. Both fell
        // through to the bilibili default before, which the CDNs
        // refuse. Ref: each room's own headers
        // (BigoRecipe.headers / LiveMeSite.headers).
        if host.contains("bigo.sg") || host.contains("bigo.tv") { return "https://www.bigo.tv/" }
        if host.contains("esxscloud.com") || host.contains("linkv.fun")
            || host.contains("liveme.com") || host.contains("emolm.com") {
            return "https://www.liveme.com/livehot"
        }
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
                    if room.isLive {
                        Text("LIVE")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(HaoLiveDesign.liveRed, in: Capsule())
                            .foregroundStyle(.white)
                    } else {
                        Text("离线")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                    if room.isLive, room.viewerCount > 0 {
                        Text(room.viewerCountText)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
            }
            Text(room.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                avatarView
                Text(room.anchorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    /// Host avatar when the platform provides one; a first-letter
    /// disc otherwise. Avatars load through the same cached loader
    /// as covers (per-host Referer + UA + retries): the old
    /// AsyncImage sent no headers at all, so any CDN that checks
    /// them left the avatar blank.
    private var avatarView: some View {
        Group {
            if let avatarURL = room.anchorAvatarURL {
                AvatarImage(url: avatarURL)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 18, height: 18)
                    .overlay(Text(String(room.anchorName.prefix(1))).font(.system(size: 9)))
            }
        }
    }
}

/// Small round avatar loaded through CoverImageCache (same
/// Referer/UA/retry behaviour as covers). Shared with the room
/// header: `size` / `fallbackText` default to the card avatar
/// (18 pt, no letter); the room header passes 32 pt + the
/// anchor's first letter.
struct AvatarImage: View {
    let url: URL?
    var size: CGFloat = 18
    var fallbackText: String = ""

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.3)
                    .overlay(
                        Text(fallbackText)
                            .font(.system(size: max(size * 0.45, 9)))
                            .opacity(fallbackText.isEmpty ? 0 : 1)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await CoverImageCache.shared.image(for: url)
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
                .buttonStyle(.interactiveCard)
            }
        }
    }
}
