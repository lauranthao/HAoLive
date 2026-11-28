// LookSite.swift
// HAo Live — NetEase LOOK Live adapter (anonymous, no login).
// Every request is a NetEase WeAPI envelope (see WeAPI.swift — the
// public browser request format, not an account secret):
//   POST https://api.look.163.com/weapi/... with form fields
//   params + encSecKey.
//   list    /weapi/livestream/homepage/recommend
//           /weapi/livestream/listen/homepage/recommend/list (audio)
//           plaintext {"offset":…,"limit":20}; video (liveType 1)
//           and audio (liveType 2) are fetched separately.
//   detail  /weapi/livestream/room/get/v3
//           plaintext {"liveRoomNo":id} -> anchor / roomInfo
//           (liveStatus 1 = live; liveUrl.hlsPullUrl / httpPullUrl,
//           host must be *.live.126.net). Two tiers: HLS + FLV.
//   chat    /weapi/livestream/chat/address
//           plaintext {"liveRoomNo":id,"os":0} -> address[] (host:port).
// Search: no server keyword search — room-ID/link direct + local
// filter of the page-1 directory snapshot.
// Danmaku: NOT implemented — the chat channel is NetEase IM
// (socket.io 1.x + NIM login), which needs the official web
// client's NIM app key; that key is not copied in, so
// danmakuStream stays the default empty stream.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LookSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .looklive

    private static let apiBase = "https://api.look.163.com"
    private static let pageSize = 20

    private static let weapiHeaders: [String: String] = [
        "Origin": "https://look.163.com",
        "Referer": "https://look.163.com/",
        "User-Agent": "Mozilla/5.0",
    ]

    enum Kind: String {
        case video, audio
    }

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        [
            LiveCategory(id: "looklive-video", platform: .looklive, name: "视频", iconName: nil),
            LiveCategory(id: "looklive-audio", platform: .looklive, name: "音频", iconName: nil),
        ]
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        // Video + audio are two separate feeds; ask both at once
        // (wzgrx _page: Future.wait, video first).
        async let video = directory(kind: .video, page: page)
        async let audio = directory(kind: .audio, page: page)
        let (videoRooms, audioRooms) = try await (video, audio)
        var seen = Set<String>()
        return (videoRooms + audioRooms).filter { seen.insert($0.roomID).inserted }
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        switch category.id {
        case "looklive-video": return try await directory(kind: .video, page: page)
        case "looklive-audio": return try await directory(kind: .audio, page: page)
        default: return []
        }
    }

    private func directory(kind: Kind, page: Int) async throws -> [LiveRoom] {
        let path = kind == .audio
            ? "/weapi/livestream/listen/homepage/recommend/list"
            : "/weapi/livestream/homepage/recommend"
        let payload = "{\"offset\":\((page - 1) * Self.pageSize),\"limit\":\(Self.pageSize)}"
        let data = try await post(path: path, plaintext: payload)
        guard data["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let body = data["data"]
        return body["itemList"].arrayValue.compactMap { item in
            guard item["type"].stringValue == "1", !item["liveData"].isNull else { return nil }
            let live = item["liveData"]
            guard let liveType = live["liveType"].intValue, liveType == 1 || liveType == 2 else { return nil }
            let actual: Kind = liveType == 2 ? .audio : .video
            guard actual == kind else { return nil }
            return Self.room(fromListLiveData: live)
        }
    }

    // MARK: - Search (ID/link direct + local filter)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        guard page == 1 else { return [] }
        let raw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        if let roomID = Self.parseRoomID(raw) {
            do {
                return [try await roomDetail(roomID: roomID)]
            } catch LiveSiteError.roomNotFound {
                return []
            }
        }
        let query = raw.lowercased()
        let rooms = try await recommendRooms(page: 1)
        return rooms.filter {
            $0.roomID.contains(query)
                || $0.anchorName.lowercased().contains(query)
                || $0.title.lowercased().contains(query)
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
        let data = try await post(path: "/weapi/livestream/room/get/v3", plaintext: "{\"liveRoomNo\":\"\(id)\"}")
        if data["code"].intValue == 404 { throw LiveSiteError.roomNotFound(roomID) }
        // wzgrx _data(room: true): 424 is app-only ("暂不支持此直播，
        // 请在APP中查看"), 555 is a private room with a password.
        if data["code"].intValue == 424 { throw LiveSiteError.message("该直播仅限 LOOK App 观看") }
        if data["code"].intValue == 555 { throw LiveSiteError.message("私密房间，需密码才能观看") }
        guard data["code"].intValue == 200 else { throw LiveSiteError.invalidResponse }
        let body = data["data"]
        let anchor = body["anchor"]
        guard anchor["liveRoomNo"].stringValue == id else { throw LiveSiteError.roomNotFound(roomID) }
        let info = body["roomInfo"]
        // wzgrx _kindOf: liveType must be 1 or 2, anything else is
        // ApiChanged.
        guard let liveType = info["liveType"].intValue, liveType == 1 || liveType == 2 else {
            throw LiveSiteError.invalidResponse
        }
        let status = body["liveStatus"].intValue ?? -1
        let isLive = status == 1
        // wzgrx LookLiveApi.room: paid = _paid(data['feeInfo']) —
        // fee set (true or non-zero) with no sessionKey (a bought
        // ticket; never for an anonymous client). App-only =
        // liveStreamType 50 with no stream address at all
        // (isAppOnly). A paid or app-only live room carries no
        // variants, so it is never handed playable URLs.
        let feeInfo = body["feeInfo"]
        let isPaid = feeInfo["fee"].boolValue == true && (feeInfo["sessionKey"].stringValue ?? "").isEmpty
        let liveURL = info["liveUrl"]
        let hasAddress = !(liveURL["hlsPullUrl"].stringValue ?? "").isEmpty
            || !(liveURL["httpPullUrl"].stringValue ?? "").isEmpty
        let isAppOnly = info["liveStreamType"].intValue == 50 && !hasAddress
        let variants = (isLive && !isPaid && !isAppOnly) ? Self.variants(fromLiveURL: liveURL) : []
        let cover = Self.imageURL(info["liveCoverUrl"].stringValue)
        // wzgrx liveRoom: avatar falls back to the cover when empty.
        let avatar = Self.imageURL(anchor["avatarUrl"].stringValue) ?? cover
        return LiveRoom(
            id: "looklive-\(id)",
            platform: .looklive,
            roomID: id,
            title: info["title"].stringValue ?? "",
            anchorName: anchor["nickName"].stringValue ?? "",
            anchorAvatarURL: avatar,
            coverURL: cover,
            categoryName: liveType == 2 ? "音频" : "视频",
            viewerCount: 0,
            isLive: isLive,
            playDataJSON: Self.variantsJSON(variants)
        )
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let id = Self.parseRoomID(room.roomID) else { return [] }
        var variants: [LookVariant] = []
        if let payload = room.playDataJSON,
           let data = payload.data(using: .utf8),
           let json = JSONValue.parse(data) {
            variants = Self.variants(fromStoredJSON: json)
        }
        if variants.isEmpty {
            // Refresh: the list snapshot may be stale or carry no URLs.
            let detail = try? await roomDetail(roomID: id)
            if let payload = detail?.playDataJSON,
               let data = payload.data(using: .utf8),
               let json = JSONValue.parse(data) {
                variants = Self.variants(fromStoredJSON: json)
            }
        }
        guard !variants.isEmpty else { return [] }
        let headers = [
            "Origin": "https://look.163.com",
            "Referer": "https://look.163.com/live?id=\(id)",
            "User-Agent": "Mozilla/5.0",
        ]
        return variants.compactMap { variant in
            guard let url = URL(string: variant.url) else { return nil }
            return PlayStream(url: url, quality: variant.proto == "hls" ? "HLS" : "FLV", line: "主线路", headers: headers)
        }
    }

    // MARK: - WeAPI transport

    /// POST a WeAPI-encrypted plaintext JSON body; returns the
    /// decoded response root. Built on URLSession directly (not
    /// HTTPClient.postForm): the base64 `params` value must be
    /// strictly form-encoded — .urlQueryAllowed leaves `+` and `/`
    /// alone, a base64 `+` would arrive as a space, corrupt the
    /// envelope, and the server answers HTTP 200 with an empty body
    /// (verified live from this VM 2026-11-28).
    private func post(path: String, plaintext: String) async throws -> JSONValue {
        let envelope = WeAPI.encryptPayload(plaintext)
        guard let url = URL(string: "\(Self.apiBase)\(path)") else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (key, value) in Self.weapiHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = "params=\(Self.formEncode(envelope.params))&encSecKey=\(Self.formEncode(envelope.encSecKey))".data(using: .utf8)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw LiveSiteError.networkUnavailable
        }
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        return json
    }

    /// Strict application/x-www-form-urlencoded encoding: only
    /// unreserved bytes stay bare.
    static func formEncode(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for byte in string.utf8 {
            switch byte {
            case 0x41...0x5a, 0x61...0x7a, 0x30...0x39, 0x2d, 0x2e, 0x5f, 0x7e:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    // MARK: - Mapping helpers

    struct LookVariant {
        var proto: String // "hls" | "flv"
        var url: String
    }

    /// Pure parser for one directory item's liveData.
    /// Testable without the network.
    static func room(fromListLiveData live: JSONValue) -> LiveRoom? {
        let user = live["userInfo"]
        guard let roomID = user["liveRoomNo"].stringValue, !roomID.isEmpty else { return nil }
        let liveType = live["liveType"].intValue ?? 1
        let variants = Self.variants(fromLiveURL: live["liveUrl"])
        let cover = Self.imageURL(live["liveCoverUrl"].stringValue)
        // wzgrx liveRoom: avatar falls back to the cover when empty.
        let avatar = Self.imageURL(user["avatarUrl"].stringValue) ?? cover
        return LiveRoom(
            id: "looklive-\(roomID)",
            platform: .looklive,
            roomID: roomID,
            title: live["liveTitle"].stringValue ?? "",
            anchorName: user["nickname"].stringValue ?? "",
            anchorAvatarURL: avatar,
            coverURL: cover,
            categoryName: liveType == 2 ? "音频" : "视频",
            viewerCount: live["onlineNumber"].intValue ?? live["popularity"].intValue ?? 0,
            isLive: true,
            playDataJSON: variantsJSON(variants)
        )
    }

    /// liveUrl -> HLS + FLV variants. A variant whose host is not
    /// *.live.126.net or whose path does not match the expected
    /// shape is dropped (never thrown for the whole room).
    static func variants(fromLiveURL liveURL: JSONValue) -> [LookVariant] {
        var out: [LookVariant] = []
        if let hls = liveURL["hlsPullUrl"].stringValue, isValidMediaURL(hls, protocol: "hls") {
            out.append(LookVariant(proto: "hls", url: hls))
        }
        if let flv = liveURL["httpPullUrl"].stringValue, isValidMediaURL(flv, protocol: "flv") {
            out.append(LookVariant(proto: "flv", url: flv))
        }
        return out
    }

    /// wzgrx mediaUri: a single-label host
    /// ^[a-z0-9-]+\.live\.126\.net$, no port, no fragment, query at
    /// most 2048 characters, path /live/<32 lower-case hex>/... .
    static func isValidMediaURL(_ raw: String, protocol proto: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host.range(of: #"^[a-z0-9-]+\.live\.126\.net$"#, options: .regularExpression) != nil,
              url.port == nil, url.user == nil, url.fragment == nil,
              (url.query?.count ?? 0) <= 2048 else { return false }
        let path = url.path
        if proto == "hls" {
            return path.range(of: #"^/live/[0-9a-f]{32}/playlist\.m3u8$"#, options: .regularExpression) != nil
        }
        return path.range(of: #"^/live/[0-9a-f]{32}\.flv$"#, options: .regularExpression) != nil
    }

    static func variantsJSON(_ variants: [LookVariant]) -> String? {
        guard !variants.isEmpty else { return nil }
        let items = variants.map { "{\"protocol\":\"\($0.proto)\",\"url\":\"\($0.url)\"}" }.joined(separator: ",")
        return "[\(items)]"
    }

    static func variants(fromStoredJSON json: JSONValue) -> [LookVariant] {
        json.arrayValue.compactMap { item in
            guard let proto = item["protocol"].stringValue,
                  let url = item["url"].stringValue, !url.isEmpty else { return nil }
            return LookVariant(proto: proto, url: url)
        }
    }

    /// Bare numeric id (2-18 digits) or a look.163.com/live?id= link.
    /// wzgrx roomIdFromUrl: http(s) on look.163.com (any case), no
    /// user info, port 80/443/none, no fragment, the one path segment
    /// `live` (any case), exactly one `id`; over 8192 chars or with
    /// control characters is refused.
    static func parseRoomID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^[1-9][0-9]{1,17}$"#, options: .regularExpression) != nil {
            return value
        }
        guard value.count <= 8192,
              !value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.lowercased() == "look.163.com",
              url.user == nil, url.fragment == nil,
              url.port == nil || url.port == 80 || url.port == 443,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let ids = components.queryItems?.filter({ $0.name == "id" }), ids.count == 1,
              let id = ids.first?.value,
              id.range(of: #"^[1-9][0-9]{1,17}$"#, options: .regularExpression) != nil else { return nil }
        // One path segment `live`, any case; empty segments ignored.
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 1, segments[0].lowercased() == "live" else { return nil }
        return id
    }
}
