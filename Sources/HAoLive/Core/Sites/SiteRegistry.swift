// SiteRegistry.swift
// HAo Live — the registry of platform adapters.
// The UI asks the registry, never a platform class directly,
// so adding a platform later is one line here.

import Foundation

enum SiteRegistry {
    /// All adapters, in display order: wzgrx's SiteIds.supported
    /// order exactly (bilibili, douyu, huya, douyin, kuaishou, cc,
    /// twitch, soop, yy, acfun, picarto, twitcasting, missevan,
    /// inke, kilakila, xiaohongshu, niconico, weibo, showroom,
    /// chzzk, kick, liveme, tiktok, youtube, bigo, pandalive,
    /// fc2live, steambroadcast, jdlive, kugoulive, baidulive,
    /// sixroom, looklive, seventeenlive), minus iptv — IPTV is
    /// not a platform adapter (user-supplied M3U playlists + EPG,
    /// a whole separate feature area), so it is not listed here.
    static let sites: [any LiveSite] = [
        BilibiliSite(),
        DouyuSite(),
        HuyaSite(),
        DouyinSite(),
        KuaishouSite(),
        CCSite(),
        TwitchSite(),
        SoopSite(),
        YYSite(),
        AcfunSite(),
        PicartoSite(),
        TwitcastingSite(),
        MissevanSite(),
        InkeSite(),
        KilakilaSite(),
        XiaohongshuSite(),
        NiconicoSite(),
        WeiboSite(),
        ShowroomSite(),
        ChzzkSite(),
        KickSite(),
        LiveMeSite(),
        TiktokSite(),
        YoutubeSite(),
        BigoSite(),
        PandaLiveSite(),
        Fc2Site(),
        SteamSite(),
        JDSite(),
        KugouSite(),
        BaiduSite(),
        SixRoomSite(),
        LookSite(),
        SeventeenLiveSite(),
    ]

    static func site(for platform: LivePlatform) -> (any LiveSite)? {
        sites.first { $0.platform == platform }
    }
}

// MARK: - Room-link parser (Pure Live's WebSearchRoomParser host table)

/// Parse a pasted room link into (platform, roomID). Host table is
/// Pure Live's, for all 34 platforms; short links are not
/// followed (no redirect chain), so paste the full room URL.
/// RoomID is always the native id the site's roomDetail takes
/// (e.g. Twitch login, YouTube video id, CHZZK 32-hex channel id).
/// Not parsed: Inke (its watch URL carries live_id, but the
/// adapter keys rooms by uid — no conversion without a fetch),
/// TikTok share/live/{roomId} (adapter keys by username),
/// YouTube channel /live (adapter keys by video id),
/// LiveMe /u/{userId} (adapter keys by short id),
/// Kilakila /room/{broadcastId} (adapter keys by owner uid),
/// niconico nico.ms short links (no redirect chain).
enum LiveURLParser {
    /// Segments that are pages, never room ids.
    private static let reserved = ["search", "category", "video", "user", "login",
                                   "directory", "categories", "about", "download",
                                   "index", "live", "signup"]

    static func parse(_ text: String) -> (platform: LivePlatform, roomID: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        // JD carries the room id in the fragment
        // (lives.jd.com/#/{liveId}); the path is empty.
        if host == "lives.jd.com" {
            guard let fragment = url.fragment else { return nil }
            let parts = fragment.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let id = parts.first, !id.isEmpty else { return nil }
            return (.jdlive, id)
        }
        guard let first = segments.first else { return nil }
        // "live" is a real path prefix on several platforms
        // (acfun / missevan / chzzk / 17live / pandalive), so the
        // reserved check applies only where the first segment IS
        // the room id (regex branches below), not globally.
        if isHost(host, domain: "huya.com") {
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            return (.huya, first)
        }
        if isHost(host, domain: "douyu.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.douyu, first)
        }
        if isHost(host, domain: "douyin.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.douyin, first)
        }
        if isHost(host, domain: "kuaishou.com") {
            // live.kuaishou.com/u/{id}
            guard segments.count >= 2, segments[0] == "u", segments[1].allSatisfy(\.isNumber) else { return nil }
            return (.kuaishou, segments[1])
        }
        if isHost(host, domain: "bilibili.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.bilibili, first)
        }
        if isHost(host, domain: "cc.163.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.cc, first)
        }
        if host == "twitch.tv" || host == "www.twitch.tv" {
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_]{4,25}$"#, options: .regularExpression) != nil else { return nil }
            return (.twitch, first.lowercased())
        }
        if host == "play.sooplive.co.kr" || host == "www.sooplive.co.kr" || host == "sooplive.co.kr" {
            // play.sooplive.co.kr/{bjid}/{bno} — adapter keys by bjid.
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            return (.soop, first)
        }
        if isHost(host, domain: "yy.com") {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.yy, first)
        }
        if host == "live.acfun.cn" {
            // live.acfun.cn/live/{authorId}
            guard segments.count >= 2, segments[0] == "live",
                  segments[1].allSatisfy(\.isNumber) else { return nil }
            return (.acfun, segments[1])
        }
        if host == "picarto.tv" || host == "www.picarto.tv" {
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else { return nil }
            return (.picarto, first)
        }
        if host == "twitcasting.tv" {
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else { return nil }
            return (.twitcasting, first)
        }
        if host == "fm.missevan.com" {
            // fm.missevan.com/live/{roomId}
            guard segments.count >= 2, segments[0] == "live",
                  segments[1].allSatisfy(\.isNumber) else { return nil }
            return (.missevan, segments[1])
        }
        if host == "live.kilakila.cn" {
            // live.kilakila.cn/zhubo/{uid} — owner page; the
            // adapter keys rooms by owner uid.
            guard segments.count >= 2, segments[0] == "zhubo",
                  segments[1].allSatisfy(\.isNumber) else { return nil }
            return (.kilakila, segments[1])
        }
        if isHost(host, domain: "xiaohongshu.com") {
            // www.xiaohongshu.com/livestream/{roomId}
            guard segments.count >= 2, segments[0] == "livestream",
                  segments[1].allSatisfy(\.isNumber) else { return nil }
            return (.xiaohongshu, segments[1])
        }
        if host == "live.nicovideo.jp" || host == "sp.live.nicovideo.jp" {
            // live.nicovideo.jp/watch/lv{...}
            guard segments.count >= 2, segments[0] == "watch",
                  segments[1].hasPrefix("lv"),
                  segments[1].dropFirst(2).allSatisfy(\.isNumber) else { return nil }
            return (.niconico, segments[1])
        }
        if isHost(host, domain: "weibo.com") {
            // weibo.com/l/wblive/{p|m}/show/{liveId}
            guard segments.count >= 4, segments[0] == "l", segments[1] == "wblive",
                  segments[2] == "p" || segments[2] == "m",
                  segments[3] == "show" else { return nil }
            guard segments.count >= 5 else { return nil }
            return (.weibo, segments[4])
        }
        if isHost(host, domain: "showroom-live.com") {
            // showroom-live.com/room/profile?room_id={id} (numeric)
            // or showroom-live.com/{room_url_key} (slug; the
            // adapter resolves it via the status endpoint).
            if segments.count >= 2, segments[0] == "room", segments[1] == "profile",
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "room_id" })?.value,
               id.allSatisfy(\.isNumber) {
                return (.showroom, id)
            }
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
            return (.showroom, first)
        }
        if host == "chzzk.naver.com" {
            // chzzk.naver.com/live/{32-hex} or /{32-hex}
            let id = segments.count >= 2 && segments[0] == "live" ? segments[1] : first
            guard id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else { return nil }
            return (.chzzk, id)
        }
        if host == "liveme.com" || host == "www.liveme.com" {
            // liveme.com/livehot/streaming/{shortId}
            guard segments.count >= 3, segments[0] == "livehot", segments[1] == "streaming",
                  segments[2].allSatisfy(\.isNumber) else { return nil }
            return (.liveme, segments[2])
        }
        if isHost(host, domain: "tiktok.com") {
            // tiktok.com/@{username}/live — adapter keys by username.
            guard segments.count >= 2, first.hasPrefix("@"), segments[1] == "live" else { return nil }
            let username = String(first.dropFirst()).lowercased()
            guard username.range(of: #"^[a-z0-9_](?:[a-z0-9._]{0,22}[a-z0-9_])?$"#, options: .regularExpression) != nil else { return nil }
            return (.tiktok, username)
        }
        if host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be" {
            // youtube.com/watch?v={videoId} | /live/{videoId} |
            // youtu.be/{videoId} — adapter keys by video id.
            if host == "youtu.be" {
                guard first.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
                return (.youtube, first)
            }
            if first == "watch",
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value,
               id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
                return (.youtube, id)
            }
            if segments.count >= 2, segments[0] == "live",
               segments[1].range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
                return (.youtube, segments[1])
            }
            return nil
        }
        if host == "bigo.tv" || host == "www.bigo.tv" {
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
            return (.bigo, first)
        }
        if isHost(host, domain: "pandalive.co.kr") {
            // pandalive.co.kr/live/play/{userId} | /channel/{userId}
            if segments.count >= 3, segments[0] == "live", segments[1] == "play" {
                return (.pandalive, segments[2])
            }
            if segments.count >= 2, segments[0] == "channel" {
                return (.pandalive, segments[1])
            }
            return nil
        }
        if host == "live.fc2.com" {
            // live.fc2.com/{channelId}/ or /{locale}/{channelId}/
            let id = segments.count >= 2 ? segments[1] : first
            guard id.allSatisfy(\.isNumber), !id.isEmpty else { return nil }
            return (.fc2live, id)
        }
        if host == "steamcommunity.com" {
            // steamcommunity.com/broadcast/watch/{steamId}
            guard segments.count >= 3, segments[0] == "broadcast", segments[1] == "watch",
                  segments[2].allSatisfy(\.isNumber) else { return nil }
            return (.steambroadcast, segments[2])
        }
        if host == "fanxing.kugou.com" {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.kugoulive, first)
        }
        if host == "live.baidu.com" {
            // live.baidu.com/m/room/{roomId}
            guard segments.count >= 3, segments[0] == "m", segments[1] == "room",
                  segments[2].allSatisfy(\.isNumber) else { return nil }
            return (.baidulive, segments[2])
        }
        if host == "v.6.cn" {
            guard first.allSatisfy(\.isNumber) else { return nil }
            return (.sixroom, first)
        }
        if host == "look.163.com" {
            // look.163.com/live?id={roomId}
            guard first == "live",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "id" })?.value,
                  !id.isEmpty else { return nil }
            return (.looklive, id)
        }
        if host == "17.live" || host == "www.17.live" {
            // 17.live/live/{roomId} or /{locale}/live/{roomId}
            let id: String
            if segments.count >= 2, segments[0] == "live" { id = segments[1] }
            else if segments.count >= 3, segments[1] == "live" { id = segments[2] }
            else { return nil }
            guard id.allSatisfy(\.isNumber) else { return nil }
            return (.seventeenlive, id)
        }
        if host == "kick.com" || host == "www.kick.com" {
            guard !reserved.contains(first),
                  first.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            return (.kick, first.lowercased())
        }
        return nil
    }

    private static func isHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
