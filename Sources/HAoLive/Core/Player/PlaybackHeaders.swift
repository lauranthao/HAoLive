// PlaybackHeaders.swift
// HAo Live — per-platform HTTP headers for stream playback.
// Swift port of Pure Live's PlaybackHeaderResolver (only the five
// platforms HAoLive ships). The player — not the API client —
// sends these when opening a stream: several CDNs reject
// header-less requests (AVPlayer sends none, which is one reason
// Huya / Kuaishou / Douyin HLS failed on device). libmpv applies
// them via http-header-fields; see MpvPlayer.
// No login is involved: cookies here are anonymous device ids
// (Douyu dy_did / acf_did) or empty when the app has none.

import Foundation

/// Playback headers per platform (Pure Live's policy, verbatim).
enum PlaybackHeaders {
    /// Desktop Chrome UA (Douyin playback; Pure Live's resolver).
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    /// macOS Chrome UA (Kuaishou playback; Pure Live's resolver).
    static let macUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    /// Bilibili's playback UA (BiliBiliSite.kDefaultUserAgent).
    static let bilibiliUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
    /// Douyu's playback UA (DouyuUtils.userAgent).
    static let douyuUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    /// Huya's native SDK UA (HuyaRequestParams.hysdkUa — the
    /// nativePlayUserAgent fallback; Pure Live also fetches
    /// play_config.json at bootstrap, whose value is older).
    static let huyaUA = "HYSDK(Windows,30000002)_APP(pc_exe&7100004&official)_SDK(trans&2.40.0.6448)"

    /// Headers the player sends when opening a stream of `platform`
    /// in room `roomID`. `cookie` is an extra Cookie value the
    /// caller already owns (Douyu did-cookie, Douyin cookie);
    /// omitted when empty.
    static func headers(platform: LivePlatform, roomID: String, cookie: String? = nil) -> [String: String] {
        var headers: [String: String]
        switch platform {
        case .bilibili:
            headers = [
                "user-agent": bilibiliUA,
                "origin": "https://live.bilibili.com",
                "referer": "https://live.bilibili.com/\(roomID)",
            ]
        case .douyu:
            headers = [
                "user-agent": douyuUA,
                "origin": "https://www.douyu.com",
                "referer": "https://www.douyu.com/\(roomID)",
            ]
        case .huya:
            headers = [
                "user-agent": huyaUA,
                "origin": "https://www.huya.com",
                "referer": "https://www.huya.com/\(roomID)",
            ]
        case .douyin:
            headers = [
                "user-agent": desktopUA,
                "origin": "https://live.douyin.com",
                "referer": "https://live.douyin.com/\(roomID)",
            ]
        case .kuaishou:
            headers = [
                "user-agent": macUA,
                "origin": "https://live.kuaishou.com",
                "referer": "https://live.kuaishou.com/u/\(roomID)",
            ]
        }
        if let cookie, !cookie.isEmpty {
            headers["cookie"] = cookie
        }
        return headers
    }
}
