// LivePlatform.swift
// HAo Live — the five first-phase live platforms.
// Platform identity only; no network code lives here.

import Foundation

/// The live platforms HAo Live supports.
/// Mirrors Pure Live's site-adapter idea (one adapter per platform),
/// but the set, order and presentation are HAo's own.
enum LivePlatform: String, CaseIterable, Codable, Hashable, Sendable {
    case bilibili
    case douyu
    case huya
    case douyin
    case kuaishou
    case cc
    case twitch
    case soop
    case yy
    case acfun
    case picarto
    case twitcasting
    case missevan
    case inke
    case kilakila
    case xiaohongshu
    case niconico
    case weibo
    case showroom
    case chzzk
    case liveme
    case tiktok
    case youtube
    case bigo
    case pandalive
    case fc2live
    case steambroadcast
    case jdlive
    case kugoulive
    case baidulive
    case sixroom
    case looklive
    case seventeenlive
    case kick

    var displayName: String {
        switch self {
        case .bilibili: return "哔哩哔哩"
        case .douyu: return "斗鱼"
        case .huya: return "虎牙"
        case .douyin: return "抖音"
        case .kuaishou: return "快手"
        case .cc: return "网易CC"
        case .twitch: return "Twitch"
        case .soop: return "SOOP"
        case .yy: return "YY直播"
        case .acfun: return "AcFun"
        case .picarto: return "Picarto"
        case .twitcasting: return "TwitCasting"
        case .missevan: return "猫耳FM"
        case .inke: return "映客"
        case .kilakila: return "Kilakila"
        case .xiaohongshu: return "小红书"
        case .niconico: return "niconico"
        case .weibo: return "微博直播"
        case .showroom: return "SHOWROOM"
        case .chzzk: return "CHZZK"
        case .liveme: return "LiveMe"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .bigo: return "Bigo Live"
        case .pandalive: return "PandaLive"
        case .fc2live: return "FC2 Live"
        case .steambroadcast: return "Steam直播"
        case .jdlive: return "京东直播"
        case .kugoulive: return "酷狗直播"
        case .baidulive: return "百度直播"
        case .sixroom: return "六间房"
        case .looklive: return "LOOK直播"
        case .seventeenlive: return "17LIVE"
        case .kick: return "Kick"
        }
    }

    /// Short label shown on room cards.
    var shortName: String {
        switch self {
        case .bilibili: return "B站"
        case .douyu: return "斗鱼"
        case .huya: return "虎牙"
        case .douyin: return "抖音"
        case .kuaishou: return "快手"
        case .cc: return "CC"
        case .twitch: return "Twitch"
        case .soop: return "SOOP"
        case .yy: return "YY"
        case .acfun: return "AcFun"
        case .picarto: return "Picarto"
        case .twitcasting: return "TwitCasting"
        case .missevan: return "猫耳"
        case .inke: return "映客"
        case .kilakila: return "Kilakila"
        case .xiaohongshu: return "小红书"
        case .niconico: return "niconico"
        case .weibo: return "微博"
        case .showroom: return "SHOWROOM"
        case .chzzk: return "CHZZK"
        case .liveme: return "LiveMe"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .bigo: return "Bigo"
        case .pandalive: return "PandaLive"
        case .fc2live: return "FC2"
        case .steambroadcast: return "Steam"
        case .jdlive: return "京东"
        case .kugoulive: return "酷狗"
        case .baidulive: return "百度"
        case .sixroom: return "六间房"
        case .looklive: return "LOOK"
        case .seventeenlive: return "17LIVE"
        case .kick: return "Kick"
        }
    }

    /// Brand colour as a hex string (models stay Foundation-only;
    /// views convert this to a Color).
    var colorHex: String {
        switch self {
        case .bilibili: return "#00A1D6"
        case .douyu: return "#FF7A00"
        case .huya: return "#FFAA00"
        case .douyin: return "#FE2C55"
        case .kuaishou: return "#FF5000"
        case .cc: return "#FF3B30"
        case .twitch: return "#9146FF"
        case .soop: return "#00A8E8"
        case .yy: return "#FF5A00"
        case .acfun: return "#FD4C5D"
        case .picarto: return "#2FA866"
        case .twitcasting: return "#0088FF"
        case .missevan: return "#FF7BAC"
        case .inke: return "#FF2E63"
        case .kilakila: return "#FF7A1A"
        case .xiaohongshu: return "#FF2442"
        case .niconico: return "#231815"
        case .weibo: return "#E6162D"
        case .showroom: return "#FF6F61"
        case .chzzk: return "#00C896"
        case .liveme: return "#FF4D8D"
        case .tiktok: return "#00F2EA"
        case .youtube: return "#FF0000"
        case .bigo: return "#FF8C00"
        case .pandalive: return "#FFC800"
        case .fc2live: return "#1E90FF"
        case .steambroadcast: return "#66C0F4"
        case .jdlive: return "#E1251B"
        case .kugoulive: return "#2BA5E0"
        case .baidulive: return "#2932E1"
        case .sixroom: return "#FF5C8A"
        case .looklive: return "#FF2D55"
        case .seventeenlive: return "#FF5A76"
        case .kick: return "#53FC18"
        }
    }

    /// The platform's web home, used as Origin / Referer for its
    /// streams (PlaybackHeaders default) and for "open in browser".
    var webBase: String {
        switch self {
        case .bilibili: return "https://live.bilibili.com"
        case .douyu: return "https://www.douyu.com"
        case .huya: return "https://www.huya.com"
        case .douyin: return "https://live.douyin.com"
        case .kuaishou: return "https://live.kuaishou.com"
        case .cc: return "https://cc.163.com"
        case .twitch: return "https://www.twitch.tv"
        case .soop: return "https://play.sooplive.co.kr"
        case .yy: return "https://www.yy.com"
        case .acfun: return "https://live.acfun.cn"
        case .picarto: return "https://picarto.tv"
        case .twitcasting: return "https://twitcasting.tv"
        case .missevan: return "https://fm.missevan.com"
        case .inke: return "https://www.inke.cn"
        case .kilakila: return "https://live.kilakila.cn"
        case .xiaohongshu: return "https://www.xiaohongshu.com"
        case .niconico: return "https://live.nicovideo.jp"
        case .weibo: return "https://weibo.com"
        case .showroom: return "https://www.showroom-live.com"
        case .chzzk: return "https://chzzk.naver.com"
        case .liveme: return "https://www.liveme.com"
        case .tiktok: return "https://www.tiktok.com"
        case .youtube: return "https://www.youtube.com"
        case .bigo: return "https://www.bigo.tv"
        case .pandalive: return "https://www.pandalive.co.kr"
        case .fc2live: return "https://live.fc2.com"
        case .steambroadcast: return "https://steamcommunity.com"
        case .jdlive: return "https://lives.jd.com"
        case .kugoulive: return "https://fanxing.kugou.com"
        case .baidulive: return "https://live.baidu.com"
        case .sixroom: return "https://v.6.cn"
        case .looklive: return "https://look.163.com"
        case .seventeenlive: return "https://17.live"
        case .kick: return "https://kick.com"
        }
    }
}
