// SoopSite.swift
// HAo Live — real SOOP adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28:
//   recommend  GET live.sooplive.co.kr/api/main_broad_list_api.php
//              ?selectType=action&selectValue=all&orderType=view_cnt
//              &pageNo=1&lang=ko_KR -> {total_cnt: 1019,
//              broad: [{user_id, broad_title, user_nick,
//              broad_thumb (//liveimg…), category_name,
//              total_view_cnt (all viewers; current_view_cnt is
//              PC-only), is_password, subscription_only, …}]}
//              (60 rooms on page 1)
//   categories GET sch.sooplive.co.kr/api.php?m=categoryList
//              &szKeyword=&szOrder=view_cnt&nPageNo=1&nListCnt=5
//              &nOffset=0&szPlatform=pc -> {data: {list:
//              [{category_no ("00040019"), category_name,
//              cate_img}]}} (verified)
//   category   GET sch.sooplive.co.kr/api.php?m=categoryContentsList
//              &szType=live&nPageNo=&nListCnt=&szPlatform=pc
//              &szOrder=view_cnt_desc&szCateNo={no}
//              (per Pure Live; NOT verified from this VM)
//   search     GET sch.sooplive.co.kr/api.php?l=DF&m=liveSearch
//              &c=UTF-8&w=webk&isMobile=0&onlyParent=1&szType=json
//              &szOrder=score&szKeyword=&nPageNo=&nListCnt=
//              &tab=live&location=total_search&isHashSearch=0&v=2.0
//              -> {REAL_BROAD: [{user_id, broad_title, user_nick,
//              broad_img, broad_cate_name, total_view_cnt}]}
//              (verified: 3 results for a Korean keyword)
//   detail     POST live.sooplive.co.kr/afreeca/player_live_api.php
//              ?bjid={id} (form bid/bno="" /type=live/pwd=""
//              /player_type=html5/stream_type=common/quality=HD
//              /mode=landing/from_api=0/is_revive=false)
//              -> {CHANNEL: {RESULT: 1, BNO: "298894933",
//              BJID, BJNICK, TITLE, RMD:
//              "https://livestream-manager.sooplive.com",
//              CDN: "gcp_cdn", VIEWPRESET: [{label: "1080p",
//              label_resolution: "1080", name: "original",
//              bps: 8000}, …, {name: "auto"}],
//              CATEGORY_TAGS: […], CHATNO: "2769",
//              CHDOMAIN: "chat-DEE93653.sooplive.com",
//              CHIP: "222.233.54.83", CHPT: "9000"}}
//              (verified: ~50 s from this VM — slow egress, the
//              endpoint itself answers 200)
//   play, step 1 GET {RMD}/broad_stream_assign.html
//              ?return_type={gs|lg}_cdn_pc_web or the CDN verbatim
//              &broad_key={BNO}-common-{quality}-hls
//              -> {result: "1", view_url:
//              "https://live-global-cdn-v02.sooplive.com/
//              live-stmc-40/auth_playlist.m3u8"} (verified)
//   play, step 2 same player_live_api POST with type=aid
//              -> {CHANNEL: {AID}}; final URL is
//              {view_url}?aid={aid} (per Pure Live; the aid call
//              itself was NOT separately curled — it is the same
//              endpoint + method already verified for detail)
// Password rooms (is_password) and subscription-only rooms are
// never listed as playable.
// Danmaku: WSS (see SoopDanmaku.swift). CHDOMAIN is the chat host,
// CHPT is the plain port, the TLS port is CHPT+1.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SoopSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .soop
    private let http = HTTPClient.shared

    private static let liveBase = "https://live.sooplive.co.kr"
    private static let searchBase = "https://sch.sooplive.co.kr"
    private static let pageSize = 30

    private static let siteHeaders: [String: String] = [
        "Accept": "*/*",
        "Origin": "https://www.sooplive.co.kr",
        "Referer": "https://www.sooplive.co.kr/",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-site",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
    ]

    /// Playback headers (Pure Live's SoopSite.getHeaders).
    private static let playHeaders: [String: String] = [
        "user-agent": PlaybackHeaders.desktopUA,
        "origin": "https://www.sooplive.co.kr",
        "referer": "https://www.sooplive.co.kr/",
    ]

    // MARK: - Categories

    /// One "热门" entry plus the site's sub-categories (the
    /// categoryList API). category_no keeps its leading zeros.
    func categories() async throws -> [LiveCategory] {
        var out: [LiveCategory] = [
            LiveCategory(id: "soop-hot", platform: .soop, name: "热门", iconName: nil)
        ]
        let json = try await http.getJSON(
            "\(Self.searchBase)/api.php?m=categoryList&szKeyword=&szOrder=view_cnt&nPageNo=1&nListCnt=120&nOffset=0&szPlatform=pc",
            headers: Self.siteHeaders
        )
        for item in json["data"]["list"].arrayValue {
            guard let no = item["category_no"].stringValue, !no.isEmpty,
                  let name = item["category_name"].stringValue, !name.isEmpty else { continue }
            out.append(LiveCategory(id: "soop-cat-\(no)", platform: .soop, name: name, iconName: nil, iconURL: Self.imageURL(item["cate_img"].stringValue)))
        }
        return out
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let json = try await http.getJSON(
            "\(Self.liveBase)/api/main_broad_list_api.php?selectType=action&selectValue=all&orderType=view_cnt&pageNo=\(page)&lang=ko_KR",
            headers: Self.siteHeaders
        )
        return json["broad"].arrayValue.compactMap(Self.room(fromBroadItem:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        if category.id == "soop-hot" { return try await recommendRooms(page: page) }
        guard category.id.hasPrefix("soop-cat-") else { return [] }
        let no = String(category.id.dropFirst("soop-cat-".count))
        let json = try await http.getJSON(
            "\(Self.searchBase)/api.php?m=categoryContentsList&szType=live&nPageNo=\(page)&nListCnt=\(Self.pageSize)&szPlatform=pc&szOrder=view_cnt_desc&szCateNo=\(no)",
            headers: Self.siteHeaders
        )
        return json["data"]["list"].arrayValue.compactMap { Self.room(fromCategoryItem: $0, categoryName: category.name) }
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    private func search(keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let json = try await http.getJSON(
            "\(Self.searchBase)/api.php?l=DF&m=liveSearch&c=UTF-8&w=webk&isMobile=0&onlyParent=1&szType=json&szOrder=score&szKeyword=\(encoded)&nPageNo=\(page)&nListCnt=\(Self.pageSize)&tab=live&location=total_search&isHashSearch=0&v=2.0",
            headers: Self.siteHeaders
        )
        return json["REAL_BROAD"].arrayValue.compactMap(Self.room(fromSearchItem:))
    }

    // MARK: - Room detail

    /// The CHANNEL object of player_live_api.php for a room.
    /// Shared with SoopDanmaku (chat host / port / chatNo).
    static func channelData(roomID: String) async throws -> JSONValue {
        let json = try await HTTPClient.shared.postFormJSON(
            "\(liveBase)/afreeca/player_live_api.php?bjid=\(roomID)",
            fields: [
                "bid": roomID,
                "bno": "",
                "type": "live",
                "pwd": "",
                "player_type": "html5",
                "stream_type": "common",
                "quality": "HD",
                "mode": "landing",
                "from_api": "0",
                "is_revive": "false",
            ],
            headers: siteHeaders
        )
        return json["CHANNEL"]
    }

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let channel = try await Self.channelData(roomID: roomID)
        guard !channel.isNull else { throw LiveSiteError.roomNotFound(roomID) }
        return Self.room(fromChannel: channel, fallbackID: roomID)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let channel: JSONValue
        if let carried = room.playDataJSON,
           let data = carried.data(using: .utf8),
           let json = JSONValue.parse(data),
           !json["BNO"].isNull {
            channel = json
        } else {
            channel = try await Self.channelData(roomID: room.roomID)
        }
        return try await Self.streams(fromChannel: channel, roomID: room.roomID)
    }

    /// Pure shape builder for a CHANNEL object: one PlayStream per
    /// VIEWPRESET entry (except "auto"), each resolved through the
    /// two-step assign + aid flow. The network steps are small
    /// instance methods below; the quality ranking is pure.
    /// Testable without the network (except the two fetches).
    static func streams(fromChannel channel: JSONValue, roomID: String) async throws -> [PlayStream] {
        guard channel["RESULT"].intValue == 1 else { return [] }
        let bno = channel["BNO"].stringValue ?? ""
        let rmd = channel["RMD"].stringValue ?? ""
        let cdn = channel["CDN"].stringValue ?? ""
        guard !bno.isEmpty, !rmd.isEmpty else { return [] }
        var presets: [(name: String, label: String, rank: Int)] = []
        for preset in channel["VIEWPRESET"].arrayValue {
            guard let name = preset["name"].stringValue, !name.isEmpty,
                  name.lowercased() != "auto" else { continue }
            let resolution = preset["label_resolution"].intValue ?? 0
            let bps = preset["bps"].intValue ?? 0
            let label = preset["label"].stringValue ?? name
            presets.append((name: name, label: label.isEmpty ? name : label, rank: resolution * 10_000 + bps))
        }
        presets.sort { $0.rank > $1.rank }
        guard !presets.isEmpty else { return [] }
        var streams: [PlayStream] = []
        for preset in presets {
            guard let urlString = try? await streamURL(rmd: rmd, cdn: cdn, bno: bno, roomID: roomID, quality: preset.name),
                  let url = URL(string: urlString), !urlString.isEmpty else { continue }
            streams.append(PlayStream(url: url, quality: preset.label, line: "主线路", headers: playHeaders))
        }
        return streams
    }

    /// One quality's URL: assign step (view_url) + aid step.
    static func streamURL(rmd: String, cdn: String, bno: String, roomID: String, quality: String) async throws -> String {
        let viewURL = try await cdnURL(rmd: rmd, cdn: cdn, bno: bno, quality: quality)
        let aid = try await streamAID(roomID: roomID, bno: bno, quality: quality)
        guard !viewURL.isEmpty, !aid.isEmpty else { return "" }
        return "\(viewURL)?aid=\(aid)"
    }

    /// Assign step: {RMD}/broad_stream_assign.html ->
    /// view_url. return_type is gs_cdn_pc_web / lg_cdn_pc_web for
    /// those CDNs, the CDN value verbatim otherwise (Pure Live).
    static func cdnURL(rmd: String, cdn: String, bno: String, quality: String) async throws -> String {
        let returnType: String
        if cdn.contains("gs_cdn") {
            returnType = "gs_cdn_pc_web"
        } else if cdn.contains("lg_cdn") {
            returnType = "lg_cdn_pc_web"
        } else {
            returnType = cdn
        }
        let base = rmd.hasSuffix("/") ? String(rmd.dropLast()) : rmd
        let json = try await HTTPClient.shared.getJSON(
            "\(base)/broad_stream_assign.html?return_type=\(returnType)&broad_key=\(bno)-common-\(quality)-hls",
            headers: siteHeaders
        )
        return json["view_url"].stringValue ?? ""
    }

    /// Aid step: player_live_api with type=aid -> CHANNEL.AID.
    static func streamAID(roomID: String, bno: String, quality: String) async throws -> String {
        let json = try await HTTPClient.shared.postFormJSON(
            "\(liveBase)/afreeca/player_live_api.php?bjid=\(roomID)",
            fields: [
                "bid": roomID,
                "bno": bno,
                "type": "aid",
                "pwd": "",
                "player_type": "html5",
                "stream_type": "common",
                "quality": quality,
                "mode": "landing",
                "from_api": "0",
                "is_revive": "false",
            ],
            headers: siteHeaders
        )
        return json["CHANNEL"]["AID"].stringValue ?? ""
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return SoopDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Mapping helpers

    /// Viewer count: total_view_cnt (or view_cnt) is the real
    /// concurrent audience; current_view_cnt is PC-only. A
    /// pc+mobile pair is summed when no total is present.
    static func viewerCount(of item: JSONValue) -> Int {
        for key in ["total_view_cnt", "view_cnt", "VIEW_CNT"] {
            if let value = item[key].intValue, value > 0 { return value }
            if let text = item[key].stringValue {
                let cleaned = text.replacingOccurrences(of: ",", with: "")
                if let value = Int(cleaned), value > 0 { return value }
            }
        }
        let pc = item["pc_view_cnt"].intValue ?? item["current_view_cnt"].intValue ?? 0
        let mobile = item["mobile_view_cnt"].intValue ?? item["m_current_view_cnt"].intValue ?? 0
        return pc + mobile
    }

    /// Password / subscription-only rooms are not playable and are
    /// never listed.
    static func isRestricted(_ item: JSONValue) -> Bool {
        item["is_password"].boolValue == true || item["subscription_only"].boolValue == true
    }

    static func avatarURL(for roomID: String) -> URL? {
        guard roomID.count >= 2 else { return nil }
        let part = String(roomID.prefix(2))
        return URL(string: "https://stimg.sooplive.co.kr/LOGO/\(part)/\(roomID)/m/\(roomID).webp")
    }

    /// Pure parser for a main_broad_list_api.php broad item.
    /// Testable without the network.
    static func room(fromBroadItem item: JSONValue) -> LiveRoom? {
        guard let roomID = item["user_id"].stringValue, !roomID.isEmpty,
              !isRestricted(item) else { return nil }
        return LiveRoom(
            id: "soop-\(roomID)",
            platform: .soop,
            roomID: roomID,
            title: item["broad_title"].stringValue ?? "",
            anchorName: item["user_nick"].stringValue ?? "",
            anchorAvatarURL: avatarURL(for: roomID),
            coverURL: Self.imageURL(item["broad_thumb"].stringValue),
            categoryName: item["category_name"].stringValue,
            viewerCount: viewerCount(of: item),
            isLive: true
        )
    }

    /// Pure parser for a categoryContentsList item.
    static func room(fromCategoryItem item: JSONValue, categoryName: String) -> LiveRoom? {
        guard let roomID = item["user_id"].stringValue, !roomID.isEmpty,
              !isRestricted(item) else { return nil }
        return LiveRoom(
            id: "soop-\(roomID)",
            platform: .soop,
            roomID: roomID,
            title: item["broad_title"].stringValue ?? "",
            anchorName: item["user_nick"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(item["user_profile_img"].stringValue),
            coverURL: Self.imageURL(item["thumbnail"].stringValue),
            categoryName: categoryName,
            viewerCount: viewerCount(of: item),
            isLive: true
        )
    }

    /// Pure parser for a liveSearch REAL_BROAD item.
    static func room(fromSearchItem item: JSONValue) -> LiveRoom? {
        guard let roomID = item["user_id"].stringValue, !roomID.isEmpty,
              !isRestricted(item) else { return nil }
        return LiveRoom(
            id: "soop-\(roomID)",
            platform: .soop,
            roomID: roomID,
            title: item["broad_title"].stringValue ?? "",
            anchorName: item["user_nick"].stringValue ?? "",
            anchorAvatarURL: avatarURL(for: roomID),
            coverURL: Self.imageURL(item["broad_img"].stringValue),
            categoryName: HaoText.firstNonEmpty(item["broad_cate_name"].stringValue, item["standard_broad_cate_name"].stringValue),
            viewerCount: viewerCount(of: item),
            isLive: true
        )
    }

    /// Pure parser for a player_live_api CHANNEL object. The whole
    /// CHANNEL rides on playDataJSON so playURLs can use the
    /// carried BNO / RMD / CDN / VIEWPRESET without re-fetching.
    /// Testable without the network.
    static func room(fromChannel channel: JSONValue, fallbackID: String) -> LiveRoom {
        let roomID = channel["BJID"].stringValue ?? fallbackID
        let bno = channel["BNO"].stringValue ?? ""
        var area: String?
        if let tags = channel["CATEGORY_TAGS"].arrayValue.first {
            area = tags.stringValue
        }
        let isLive = channel["RESULT"].intValue == 1 && !channel["VIEWPRESET"].isNull
        let cover: URL?
        if !bno.isEmpty {
            let millis = Int(Date().timeIntervalSince1970 * 1000)
            cover = URL(string: "https://liveimg.sooplive.co.kr/m/\(bno)?_t=\(millis)")
        } else {
            cover = nil
        }
        let avatar: URL?
        if roomID.count >= 2 {
            let part = String(roomID.prefix(2))
            avatar = URL(string: "https://stimg.sooplive.co.kr/LOGO/\(part)/\(roomID)/\(roomID).jpg")
        } else {
            avatar = nil
        }
        return LiveRoom(
            id: "soop-\(roomID)",
            platform: .soop,
            roomID: roomID,
            title: channel["TITLE"].stringValue ?? "",
            anchorName: channel["BJNICK"].stringValue ?? "",
            anchorAvatarURL: avatar,
            coverURL: cover,
            categoryName: area,
            viewerCount: viewerCount(of: channel),
            isLive: isLive,
            playDataJSON: channel.jsonString
        )
    }
}
