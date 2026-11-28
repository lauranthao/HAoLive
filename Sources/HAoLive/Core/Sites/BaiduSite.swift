// BaiduSite.swift
// HAo Live — Baidu Live adapter, detail-direct only (anonymous).
//
// RED LINE — the list feed (POST tiebac.baidu.com/livefeed/feed)
// signs its parameters with a hard-coded secret embedded in the
// reference. That secret is NOT copied here, so the list is NOT
// implemented: categories() / recommendRooms() / categoryRooms()
// all return [] on purpose. Only the unsigned detail route is
// implemented:
//   detail  GET mbd.baidu.com/searchbox?cmd=371&action=star
//           &service=bdbox&osname=pc&data={"data":{"room_id":id,
//           "device_id":…,"source_type":0},…}&ua=360_740_ANDROID_0
//           &bd_vid=&uid=&_={ms}
//           -> data.371 (host/video: nick_name/image/title/cover/
//           online_users/real_fans_num + video variants).
//           No signature is needed for this route.
// Search: room-ID/link direct only (no keyword search).
// Danmaku: HLS chat-playlist polling (BaiduDanmaku) — the chat list
// URLs come from the same detail response, no secret involved.
// Paid rooms (has_pay_service>0) and forbidden rooms are returned
// by detail but playURLs returns [] for them.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BaiduSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .baidulive
    private let http = HTTPClient.shared

    private static let detailBase = "https://mbd.baidu.com"

    private static let apiHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        "Accept": "application/json, text/plain, */*",
        "Origin": "https://live.baidu.com",
        "Referer": "https://live.baidu.com/",
    ]

    // MARK: - Lists: NOT implemented (signed feed secret, see header)

    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] { [] }

    func recommendRooms(page: Int) async throws -> [LiveRoom] { [] }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { [] }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] { [] }

    // MARK: - Search (ID/link direct only)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        guard page == 1 else { return [] }
        guard let roomID = Self.parseRoomID(keyword) else { return [] }
        do {
            return [try await roomDetail(roomID: roomID)]
        } catch LiveSiteError.roomNotFound {
            return []
        }
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: page)
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let id = Self.parseRoomID(roomID) else { throw LiveSiteError.roomNotFound(roomID) }
        let deviceID = "pc-\(String(Int(Date().timeIntervalSince1970 * 1_000_000), radix: 36))baidulive"
        let dataObject: [String: Any] = [
            "data": ["room_id": id, "device_id": deviceID, "source_type": 0],
            "replay_slice": 0,
            "nid": "",
            "schemeParams": [
                "src_pre": "pc",
                "src_suf": "other",
                "bd_vid": "",
                "share_uid": "",
                "share_cuk": "",
                "share_ecid": "",
                "zb_tag": "",
                "shareTaskInfo": "{\"room_id\":\"\(id)\"}",
                "share_from": "",
                "ext_params": "",
                "nid": "",
            ] as [String: Any],
        ]
        guard let dataJSON = try? JSONSerialization.data(withJSONObject: dataObject, options: []),
              let dataString = String(data: dataJSON, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        var components = URLComponents(string: "\(Self.detailBase)/searchbox")!
        components.queryItems = [
            URLQueryItem(name: "cmd", value: "371"),
            URLQueryItem(name: "action", value: "star"),
            URLQueryItem(name: "service", value: "bdbox"),
            URLQueryItem(name: "osname", value: "pc"),
            URLQueryItem(name: "data", value: dataString),
            URLQueryItem(name: "ua", value: "360_740_ANDROID_0"),
            URLQueryItem(name: "bd_vid", value: ""),
            URLQueryItem(name: "uid", value: deviceID),
            URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))"),
        ]
        guard let urlString = components.url?.absoluteString else { throw LiveSiteError.invalidResponse }
        let json = try await http.getJSON(urlString, headers: Self.apiHeaders)
        guard json["errno"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        let command = json["data"]["371"]
        guard !command.isNull, !command.objectValue.isEmpty else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        if let errorCode = command["error_code"].intValue, errorCode != 0 {
            if errorCode == 1 || errorCode == 4 { throw LiveSiteError.roomNotFound(roomID) }
            throw LiveSiteError.invalidResponse
        }
        return Self.room(fromDetailCommand: command, roomID: id)
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let id = Self.parseRoomID(room.roomID) else { return [] }
        var variants: [BaiduVariant] = []
        if let payload = room.playDataJSON,
           let data = payload.data(using: .utf8),
           let json = JSONValue.parse(data) {
            variants = Self.variants(fromStoredJSON: json["variants"])
        }
        if variants.isEmpty {
            if let detail = try? await roomDetail(roomID: id),
               let payload = detail.playDataJSON,
               let data = payload.data(using: .utf8),
               let json = JSONValue.parse(data) {
                variants = Self.variants(fromStoredJSON: json["variants"])
            }
        }
        let headers = [
            "User-Agent": Self.apiHeaders["User-Agent"] ?? "",
            "Origin": "https://live.baidu.com",
            "Referer": "https://live.baidu.com/m/room/\(id)",
        ]
        var out: [PlayStream] = []
        for variant in variants {
            for urlString in variant.urls {
                guard let url = URL(string: urlString) else { continue }
                let quality = variant.resolution > 0 ? "\(variant.resolution)p" : "原画"
                out.append(PlayStream(url: url, quality: quality, line: "\(variant.proto.uppercased())·\(variant.codec.uppercased())", headers: headers))
            }
        }
        return out
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return BaiduDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }

    // MARK: - Danmaku args (for BaiduDanmaku)

    /// Chat-list URLs for a room, from its detail response.
    static func danmakuArgs(roomID: String) async -> BaiduDanmakuArgs? {
        guard let detail = try? await BaiduSite().roomDetail(roomID: roomID),
              let payload = detail.playDataJSON,
              let data = payload.data(using: .utf8),
              let json = JSONValue.parse(data),
              let chatURL = json["chatListUrl"].stringValue, !chatURL.isEmpty else { return nil }
        return BaiduDanmakuArgs(
            chatListURL: chatURL,
            reliableListURL: json["reliableListUrl"].stringValue ?? "",
            hostListURL: json["hostListUrl"].stringValue ?? "",
            pollIntervalSeconds: json["pollInterval"].intValue ?? 5,
            roomID: detail.roomID
        )
    }

    // MARK: - Mapping helpers

    struct BaiduVariant {
        var proto: String // "hls" | "flv"
        var resolution: Int
        var codec: String // "avc" | "hevc"
        var urls: [String]
    }

    /// Pure parser for a data.371 command object.
    /// Testable without the network.
    static func room(fromDetailCommand command: JSONValue, roomID: String) -> LiveRoom {
        let host = command["host"]
        let video = command["video"]
        let status = command["status"].intValue ?? -1
        let isLive = status == 0
        let nick = HaoText.firstNonEmpty(host["nick_name"].stringValue, host["name"].stringValue) ?? "Baidu Live"
        let cover = video["cover"]
        // Paid / forbidden rooms are not playable: no variants.
        let restricted = (command["is_forbidden_url"].intValue ?? 0) > 0
            || (command["ban_status"].intValue ?? 0) > 0
            || (command["has_pay_service"].intValue ?? 0) > 0
        let variants = (isLive && !restricted) ? variants(fromVideo: video, roomID: roomID) : []
        let chat = chatArgs(command: command, video: video, roomID: roomID)
        return LiveRoom(
            id: "baidulive-\(roomID)",
            platform: .baidulive,
            roomID: roomID,
            title: HaoText.firstNonEmpty(video["title"].stringValue, nick) ?? nick,
            anchorName: nick,
            anchorAvatarURL: Self.imageURL(host["image"]["image_33"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(cover["cover_100"].stringValue, cover["vertical_cover"].stringValue)),
            categoryName: command["category"].stringValue,
            viewerCount: isLive ? (command["online_users"].intValue ?? 0) : 0,
            isLive: isLive,
            playDataJSON: playDataJSON(variants: variants, chat: chat)
        )
    }

    /// Paid / forbidden rooms get no variants: playURLs returns [].
    static func variants(fromVideo video: JSONValue, roomID: String) -> [BaiduVariant] {
        var grouped: [String: BaiduVariant] = [:]
        func add(_ raw: String?, proto: String, resolution: Int, codec: String) {
            guard let raw, !raw.isEmpty,
                  let uri = validateMediaURL(raw, roomID: roomID, protocol: proto) else { return }
            let key = "\(proto):\(resolution):\(codec)"
            if grouped[key] == nil {
                grouped[key] = BaiduVariant(proto: proto, resolution: resolution, codec: codec, urls: [])
            }
            if !grouped[key]!.urls.contains(uri) { grouped[key]!.urls.append(uri) }
        }
        for item in video["url_clarity_list"].arrayValue {
            let resolution = item["resolution"].intValue ?? 0
            let urls = item["urls"]
            add(urls["avc_flv"].stringValue, proto: "flv", resolution: resolution, codec: "avc")
            add(urls["flv"].stringValue, proto: "flv", resolution: resolution, codec: "avc")
            add(urls["hls"].stringValue, proto: "hls", resolution: resolution, codec: "avc")
            add(urls["hevc_flv"].stringValue, proto: "flv", resolution: resolution, codec: "hevc")
        }
        for item in video["url_list"].arrayValue {
            let resolution = item["resolution"].intValue ?? 0
            for rawURLs in item["urls"].arrayValue {
                add(rawURLs["flv"].stringValue, proto: "flv", resolution: resolution, codec: "avc")
                add(rawURLs["hls"].stringValue, proto: "hls", resolution: resolution, codec: "avc")
            }
        }
        let hls = video["live_hls_url"].stringValue ?? ""
        add(hls.isEmpty ? nil : hls, proto: "hls", resolution: resolutionFor(hls, urlList: video["url_list"]), codec: "avc")
        if video["url_clarity_list"].arrayValue.isEmpty {
            add(video["live_flv_url"].stringValue, proto: "flv", resolution: 0, codec: "avc")
            add(video["live_flv_url_origin"].stringValue, proto: "flv", resolution: 0, codec: "avc")
        }
        add(video["hevc_url"].stringValue, proto: "flv", resolution: 0, codec: "hevc")
        return grouped.values.sorted {
            if $0.resolution != $1.resolution { return $0.resolution > $1.resolution }
            return $0.proto < $1.proto
        }
    }

    private static func resolutionFor(_ raw: String, urlList: JSONValue) -> Int {
        guard let candidate = URL(string: raw), !candidate.pathComponents.isEmpty else { return 0 }
        let name = candidate.pathComponents.last ?? ""
        for item in urlList.arrayValue {
            guard let resolution = item["resolution"].intValue, resolution > 0 else { continue }
            for rawURLs in item["urls"].arrayValue {
                guard let hls = URL(string: rawURLs["hls"].stringValue ?? ""),
                      hls.pathComponents.last == name else { continue }
                return resolution
            }
        }
        return 0
    }

    /// Media URLs are used verbatim (signed query kept). Host must
    /// be a Baidu live host, path must start with /live/, end with
    /// the protocol extension, and mention this room id.
    static func validateMediaURL(_ raw: String, roomID: String, protocol proto: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              (host == "hls-live.bdstatic.com" || host == "flv-live.bdstatic.com" || host.hasSuffix(".liveshow.bdstatic.com")),
              url.user == nil, url.fragment == nil,
              url.path.hasPrefix("/live/"),
              url.path.lowercased().hasSuffix(proto == "hls" ? ".m3u8" : ".flv"),
              url.path.contains(roomID) else { return nil }
        return url.absoluteString
    }

    struct ChatArgs {
        var chatListURL: String
        var reliableListURL: String
        var hostListURL: String
        var pollIntervalSeconds: Int
    }

    static func chatArgs(command: JSONValue, video: JSONValue, roomID: String) -> ChatArgs? {
        func firstText(_ values: [JSONValue]) -> String {
            for value in values {
                if let text = value.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    return text.trimmingCharacters(in: .whitespaces)
                }
            }
            return ""
        }
        let chat = firstText([command["chat_msg_hls_url"], video["msg_hls_url"]])
        guard !chat.isEmpty else { return nil }
        let rawInterval = command["msg_hls_pull_internal_in_second"].intValue ?? video["msg_hls_pull_internal_in_second"].intValue ?? 5
        return ChatArgs(
            chatListURL: chat,
            reliableListURL: firstText([command["reliable_msg_hls_url"]]),
            hostListURL: firstText([command["host_msg_hls_url"]]),
            pollIntervalSeconds: min(max(rawInterval, 1), 10)
        )
    }

    static func playDataJSON(variants: [BaiduVariant], chat: ChatArgs?) -> String? {
        guard !variants.isEmpty || chat != nil else { return nil }
        let variantItems = variants.map { variant in
            let urls = variant.urls.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"protocol\":\"\(variant.proto)\",\"resolution\":\(variant.resolution),\"codec\":\"\(variant.codec)\",\"urls\":[\(urls)]}"
        }.joined(separator: ",")
        var parts = ["\"variants\":[\(variantItems)]"]
        if let chat {
            parts.append("\"chatListUrl\":\"\(chat.chatListURL)\"")
            parts.append("\"reliableListUrl\":\"\(chat.reliableListURL)\"")
            parts.append("\"hostListUrl\":\"\(chat.hostListURL)\"")
            parts.append("\"pollInterval\":\(chat.pollIntervalSeconds)")
        }
        return "{\(parts.joined(separator: ","))}"
    }

    static func variants(fromStoredJSON json: JSONValue) -> [BaiduVariant] {
        json.arrayValue.compactMap { item in
            guard let proto = item["protocol"].stringValue,
                  let resolution = item["resolution"].intValue,
                  let codec = item["codec"].stringValue else { return nil }
            let urls = item["urls"].arrayValue.compactMap { $0.stringValue }
            guard !urls.isEmpty else { return nil }
            return BaiduVariant(proto: proto, resolution: resolution, codec: codec, urls: urls)
        }
    }

    /// Bare numeric id (6-20 digits) or a live.baidu.com link:
    /// /m/room/{id}, or ?room_id= on the pchome / multipage paths.
    static func parseRoomID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^[1-9][0-9]{5,19}$"#, options: .regularExpression) != nil {
            return value
        }
        guard let url = URL(string: value),
              url.host?.lowercased() == "live.baidu.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count == 3, segments[0] == "m", segments[1] == "room",
           segments[2].range(of: #"^[1-9][0-9]{5,19}$"#, options: .regularExpression) != nil {
            return segments[2]
        }
        guard let roomID = components.queryItems?.first(where: { $0.name == "room_id" })?.value,
              roomID.range(of: #"^[1-9][0-9]{5,19}$"#, options: .regularExpression) != nil else { return nil }
        let path = "/" + segments.joined(separator: "/")
        if path == "/m/media/pclive/pchome/live.html" { return roomID }
        if segments.count == 6, segments[0..<5].joined(separator: "/") == "m/media/multipage/liveshow/index" {
            return roomID
        }
        return nil
    }
}
