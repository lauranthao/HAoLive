// PandaLiveSite.swift
// HAo Live — PandaLive (판다라이브) adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-28 (the survey
// reported HTTP 000 for /v1/live/index; it now answers 200):
//   list    POST api.pandalive.co.kr/v1/live/index
//           form offset/limit/orderBy=hot
//           -> {result: true, page: {offset, limit, total, page},
//              list: [{userId, userIdx, userNick, title, userImg,
//              thumbUrl, category, user, fanCnt, isAdult, isPw,
//              isLive}]} (total 127 at probe time)
//   search  same endpoint, orderBy=user&searchVal= (live rooms)
//   anchors POST /v1/live/bj_list form offset/limit/searchVal=
//           (BJ profiles, live or offline; media may be absent)
//   detail  POST /v1/member/bj form userId/info="media fanGrade"
//           -> {result, bjInfo: {id, nick, idx, thumbUrl,
//              channelTitle, channelDesc, fanCnt}, media:
//              {userId, userIdx, title, isLive, ...}}
//           then POST /v1/live/play form action=watch&userId=&
//           password=&shareLinkType=
//           -> {result, media, PlayList: {hls3/hls2/hls:
//              [{url}]}, channel, token, errorData: {code}}
//           errorData.code: castEnd = ended, needAdult = adult
//           verification, needPassword/password = password room,
//           anything else = restricted — all skipped for playback.
//   stream  HLS master (host *.live-video.net, .m3u8; the token
//           in its query is SINGLE-USE — the first fetch returned
//           200, a re-fetch of the same URL 403, so the master is
//           always fetched fresh and never cached). The master is
//           parsed into variants (RESOLUTION / FRAME-RATE /
//           BANDWIDTH) for multiple tiers.
//   Headers: Origin/Referer https://www.pandalive.co.kr on every
//   call (media tokens are Origin-bound), Accept-Language ko-KR.
// Adult / password rooms are listed nowhere as playable: list
// and search skip isAdult / isPw rows, and playURLs returns []
// for them. Danmaku: chat-ws channel, see PandaLiveDanmaku.swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PandaLiveSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .pandalive
    private let http = HTTPClient.shared

    private static let apiBase = "https://api.pandalive.co.kr"
    private static let origin = "https://www.pandalive.co.kr"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private static func headers(referer: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "ko-KR,ko;q=0.9,en;q=0.8",
            "Origin": origin,
            "Referer": referer,
        ]
    }

    private static func mediaHeaders(userID: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Origin": origin,
            "Referer": "\(origin)/live/play/\(userID)",
        ]
    }

    // MARK: - Lists

    /// No category tree on PandaLive.
    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] {
        try await directory(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await directory(page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await recommendRooms()
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        try await recommendRooms(page: page)
    }

    private func directory(page: Int, pageSize: Int = 30) async throws -> [LiveRoom] {
        guard page >= 1, pageSize >= 1, pageSize <= 50 else { return [] }
        let json = try await http.postFormJSON(
            "\(Self.apiBase)/v1/live/index",
            fields: [
                "offset": String((page - 1) * pageSize),
                "limit": String(pageSize),
                "orderBy": "hot",
            ],
            headers: Self.headers(referer: "\(Self.origin)/live"))
        guard json["result"].boolValue == true else { throw LiveSiteError.invalidResponse }
        return json["list"].arrayValue.compactMap(Self.room(fromCard:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchAnchors(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, query.count <= 100 else { return [] }
        // A bare user id or a pandalive link resolves straight to
        // that BJ's room.
        if let userID = Self.userID(from: query), page == 1,
           let room = try? await roomDetail(roomID: userID), room.isLive {
            return [room]
        }
        let pageSize = 10
        let json = try await http.postFormJSON(
            "\(Self.apiBase)/v1/live/index",
            fields: [
                "offset": String((page - 1) * pageSize),
                "limit": String(pageSize),
                "orderBy": "user",
                "searchVal": query,
            ],
            headers: Self.headers(referer: "\(Self.origin)/search/live?text=\(query)"))
        guard json["result"].boolValue == true else { throw LiveSiteError.invalidResponse }
        return json["list"].arrayValue.compactMap(Self.room(fromCard:))
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        guard page >= 1 else { return [] }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, query.count <= 100 else { return [] }
        let pageSize = 10
        let json = try await http.postFormJSON(
            "\(Self.apiBase)/v1/live/bj_list",
            fields: [
                "offset": String((page - 1) * pageSize),
                "limit": String(pageSize),
                "searchVal": query,
            ],
            headers: Self.headers(referer: "\(Self.origin)/search/bj?text=\(query)"))
        guard json["result"].boolValue == true else { throw LiveSiteError.invalidResponse }
        return json["list"].arrayValue.compactMap(Self.room(fromSearchProfile:))
    }

    /// Normalize a BJ user id from a bare id or a pandalive link
    /// (/live/play/{id}, /channel/{id}, /channel/{id}/home).
    /// Testable without the network.
    static func userID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isValidUserID(text) { return text }
        guard let url = URL(string: text),
              let host = url.host?.lowercased(),
              host == "pandalive.co.kr" || host == "www.pandalive.co.kr" || host == "m.pandalive.co.kr" else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count == 3, segments[0].lowercased() == "live", segments[1].lowercased() == "play" {
            return Self.isValidUserID(segments[2]) ? segments[2] : nil
        }
        if segments.count == 2, segments[0].lowercased() == "channel" {
            return Self.isValidUserID(segments[1]) ? segments[1] : nil
        }
        if segments.count == 3, segments[0].lowercased() == "channel", segments[2].lowercased() == "home" {
            return Self.isValidUserID(segments[1]) ? segments[1] : nil
        }
        return nil
    }

    /// BJ ids are [A-Za-z0-9_]{1,64}, optionally with a
    /// @social suffix (e.g. 1506087545@ka).
    static func isValidUserID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 81, !text.contains(" ") else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let main = parts[0]
        guard !main.isEmpty, main.count <= 64,
              main.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        if parts.count == 2 {
            let suffix = parts[1]
            guard suffix.count >= 2, suffix.count <= 16,
                  suffix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        return true
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let userID = Self.userID(from: roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let room = try await Self.fetchRoom(userID: userID)
        return Self.liveRoom(from: room)
    }

    /// Pure mapper from a fetched room to the UI model. Restricted
    /// rooms stay listed with isLive true, but playURLs returns []
    /// for them — they are never offered as playable.
    static func liveRoom(from room: RoomData) -> LiveRoom {
        LiveRoom(
            id: "pandalive-\(room.userID)",
            platform: .pandalive,
            roomID: room.userID,
            title: room.title,
            anchorName: room.nickname,
            anchorAvatarURL: Self.imageURL(room.avatar),
            coverURL: Self.imageURL(room.cover),
            categoryName: room.category.isEmpty ? nil : room.category,
            viewerCount: room.onlineViewers ?? 0,
            isLive: room.isLive,
            playDataJSON: room.chatToken.isEmpty ? nil :
                "{\"channel\":\"\(room.chatChannel)\",\"token\":\"\(room.chatToken)\"}"
        )
    }

    // MARK: - Play URLs

    /// Always re-fetched fresh: the HLS master token is
    /// single-use, so a carried URL would already be dead.
    /// Restricted / offline rooms yield [].
    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let userID = Self.userID(from: room.roomID) else { return [] }
        let data = try await Self.fetchRoom(userID: userID)
        guard data.isLive, data.access == .public, !data.streams.isEmpty else { return [] }
        let headers = Self.mediaHeaders(userID: userID)
        return data.streams.map { stream in
            PlayStream(url: stream.url, quality: stream.label, line: "主线路", headers: headers)
        }
    }

    /// Fresh chat channel + token for the danmaku socket.
    /// (PandaLiveDanmaku calls this; tokens expire, so it is
    /// re-fetched on every reconnect too.)
    static func chatArgs(userID: String) async -> (channel: String, token: String)? {
        guard let room = try? await fetchRoom(userID: userID),
              room.isLive, room.access == .public,
              !room.chatToken.isEmpty else { return nil }
        return (channel: room.chatChannel.isEmpty ? userID : room.chatChannel,
                token: room.chatToken)
    }

    // MARK: - Room fetching (member/bj + live/play + manifest)

    enum Access: String {
        case `public`
        case password
        case adult
        case restricted
    }

    struct PandaStream {
        let id: String
        let label: String
        let height: Int
        let frameRate: Double
        let bandwidth: Int
        let url: URL
    }

    struct RoomData {
        let userID: String
        let userIndex: Int
        let nickname: String
        let title: String
        let avatar: String?
        let cover: String?
        let category: String
        let followers: Int?
        let onlineViewers: Int?
        let isLive: Bool
        let access: Access
        let streams: [PandaStream]
        let chatChannel: String
        let chatToken: String
        let isRerun: Bool
    }

    /// Full room fetch: profile, then the play call, then the HLS
    /// master manifest. Returns an offline / restricted RoomData
    /// (never throws) for ended, adult, password and other
    /// restricted rooms; throws only on transport / schema errors
    /// and on an unknown user id.
    static func fetchRoom(userID: String) async throws -> RoomData {
        let referer = "\(origin)/live/play/\(userID)"
        let member = try await HTTPClient.shared.postFormJSON(
            "\(apiBase)/v1/member/bj",
            fields: ["userId": userID, "info": "media fanGrade"],
            headers: headers(referer: referer))
        guard member["result"].boolValue == true else {
            if (member["message"].stringValue ?? "").contains("유저 정보가 없습니다") {
                throw LiveSiteError.roomNotFound(userID)
            }
            throw LiveSiteError.invalidResponse
        }
        let profile = member["bjInfo"]
        guard let profileID = profile["id"].stringValue,
              profileID.lowercased() == userID.lowercased(),
              let profileIndex = profile["idx"].intValue, profileIndex > 0 else {
            throw LiveSiteError.invalidResponse
        }
        let nick = profile["nick"].stringValue ?? ""
        let base = RoomData(
            userID: userID, userIndex: profileIndex, nickname: nick,
            title: HaoText.firstNonEmpty(profile["channelTitle"].stringValue, nick) ?? nick,
            avatar: imageString(profile["thumbUrl"]),
            cover: imageString(profile["channelBannerUrl"]),
            category: "",
            followers: profile["fanCnt"].intValue,
            onlineViewers: nil, isLive: false, access: .public,
            streams: [], chatChannel: "", chatToken: "", isRerun: false)
        let mediaValue = member["media"]
        guard !mediaValue.isNull else { return base }
        let media = mediaValue
        guard let mediaID = media["userId"].stringValue,
              mediaID.lowercased() == userID.lowercased(),
              media["userIdx"].intValue == profileIndex else {
            throw LiveSiteError.invalidResponse
        }
        let play = try await HTTPClient.shared.postFormJSON(
            "\(apiBase)/v1/live/play",
            fields: ["action": "watch", "userId": userID, "password": "", "shareLinkType": ""],
            headers: headers(referer: referer))
        guard play["result"].boolValue == true else {
            let code = play["errorData"]["code"].stringValue ?? ""
            if code == "castEnd" { return base }
            let access: Access = {
                switch code {
                case "needAdult": return .adult
                case "needPassword", "password": return .password
                default: return .restricted
                }
            }()
            return restrictedRoom(base: base, media: media, access: access)
        }
        let playMedia = play["media"]
        guard let playMediaID = playMedia["userId"].stringValue,
              playMediaID.lowercased() == userID.lowercased(),
              playMedia["userIdx"].intValue == profileIndex else {
            throw LiveSiteError.invalidResponse
        }
        guard playMedia["isLive"].boolValue == true else { return base }
        guard let master = firstMasterURL(from: play["PlayList"]) else {
            throw LiveSiteError.message("该直播间暂无可播流")
        }
        // The master token is single-use: fetch it fresh, now.
        let manifestData = try await HTTPClient.shared.get(
            master.absoluteString, headers: headers(referer: referer))
        guard let manifest = String(data: manifestData, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        let streams = parseManifest(master: master, text: manifest)
        guard !streams.isEmpty else {
            throw LiveSiteError.message("该直播间暂无可播流")
        }
        let channel = play["channel"].stringValue ?? ""
        return RoomData(
            userID: userID, userIndex: profileIndex,
            nickname: HaoText.firstNonEmpty(media["userNick"].stringValue, nick) ?? nick,
            title: HaoText.firstNonEmpty(
                media["title"].stringValue, profile["channelTitle"].stringValue, nick) ?? nick,
            avatar: imageString(HaoText.firstNonEmpty(media["userImg"].stringValue, profile["thumbUrl"].stringValue)),
            cover: imageString(HaoText.firstNonEmpty(
                media["thumbUrl"].stringValue, media["ivsThumbnail"].stringValue, profile["channelBannerUrl"].stringValue)),
            category: media["category"].stringValue ?? "",
            followers: media["fanCnt"].intValue ?? profile["fanCnt"].intValue,
            onlineViewers: media["user"].intValue,
            isLive: true, access: .public, streams: streams,
            chatChannel: channel.isEmpty ? userID : channel,
            chatToken: play["token"].stringValue ?? "",
            isRerun: isRerun(media))
    }

    private static func restrictedRoom(base: RoomData, media: JSONValue, access: Access) -> RoomData {
        RoomData(
            userID: base.userID, userIndex: base.userIndex,
            nickname: HaoText.firstNonEmpty(media["userNick"].stringValue, base.nickname) ?? base.nickname,
            title: HaoText.firstNonEmpty(
                media["title"].stringValue, base.title) ?? base.title,
            avatar: imageString(HaoText.firstNonEmpty(media["userImg"].stringValue, base.avatar)),
            cover: imageString(HaoText.firstNonEmpty(media["thumbUrl"].stringValue, base.cover)),
            category: media["category"].stringValue ?? "",
            followers: media["fanCnt"].intValue ?? base.followers,
            onlineViewers: media["user"].intValue,
            isLive: true, access: access,
            streams: [], chatChannel: "", chatToken: "",
            isRerun: isRerun(media))
    }

    /// hls3 first, then hls2, then hls. Each entry is a list of
    /// {url} (a lone {url} object is also accepted). The URL must
    /// be an https *.live-video.net .m3u8 master.
    static func firstMasterURL(from playlist: JSONValue) -> URL? {
        for key in ["hls3", "hls2", "hls"] {
            let value = playlist[key]
            guard !value.isNull else { continue }
            let items = value.arrayValue.isEmpty && !value.isNull ? [value] : value.arrayValue
            for item in items {
                guard let raw = item["url"].stringValue,
                      let url = mediaMasterURL(raw) else { continue }
                return url
            }
        }
        return nil
    }

    /// Validate an HLS master URL (https, *.live-video.net,
    /// .m3u8) and return it VERBATIM. Testable without the network.
    static func mediaMasterURL(_ raw: String) -> URL? {
        guard !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host.hasSuffix(".live-video.net"),
              url.path.lowercased().hasSuffix(".m3u8") else { return nil }
        return url
    }

    /// Parse an HLS master manifest into variant streams, best
    /// first (height, then frame rate, then bandwidth). Variant
    /// URIs resolve against the master URL. A variant without a
    /// RESOLUTION is skipped (rather than failing the whole list).
    /// Testable without the network.
    static func parseManifest(master: URL, text: String) -> [PandaStream] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var streams: [PandaStream] = []
        var seenIDs = Set<String>()
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            let attributes = streamAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            var next = index + 1
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                next += 1
            }
            guard next < lines.count else { break }
            let uriLine = lines[next].trimmingCharacters(in: .whitespaces)
            guard !uriLine.hasPrefix("#"),
                  let resolution = attributes["RESOLUTION"],
                  let height = resolutionHeight(resolution),
                  let variantURL = URL(string: uriLine, relativeTo: master)?.absoluteURL else {
                index = next + 1
                continue
            }
            let frameRate = Double(attributes["FRAME-RATE"] ?? "") ?? 0
            let bandwidth = Int(attributes["BANDWIDTH"] ?? "") ?? 0
            let fpsSuffix = frameRate >= 50 ? "60" : frameRate >= 25 ? "30" : ""
            let baseID = "\(height)p\(fpsSuffix)"
            let id = seenIDs.contains(baseID) ? "\(baseID)_\(streams.count + 1)" : baseID
            seenIDs.insert(id)
            streams.append(PandaStream(
                id: id, label: baseID, height: height,
                frameRate: frameRate, bandwidth: bandwidth, url: variantURL))
            index = next + 1
        }
        streams.sort {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.frameRate != $1.frameRate { return $0.frameRate > $1.frameRate }
            return $0.bandwidth > $1.bandwidth
        }
        return streams
    }

    /// Parse `KEY=value,KEY="quoted,value"` attribute lists
    /// (quoted values may contain commas). Testable without the network.
    static func streamAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false
        var index = raw.startIndex
        func flush() {
            if !key.isEmpty { result[key] = value }
            key = ""
            value = ""
            readingKey = true
        }
        while index < raw.endIndex {
            let ch = raw[index]
            if inQuotes {
                if ch == "\"" { inQuotes = false } else { value.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
            } else if readingKey, ch == "=" {
                readingKey = false
            } else if !readingKey, ch == "," {
                flush()
            } else if readingKey {
                key.append(ch)
            } else {
                value.append(ch)
            }
            index = raw.index(after: index)
        }
        flush()
        return result
    }

    /// Height from a "WxH" resolution string.
    static func resolutionHeight(_ resolution: String) -> Int? {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let height = Int(parts[1]), height > 0 else { return nil }
        return height
    }

    // MARK: - Card parsing

    /// Pure parser for a /v1/live/index row. Nil when the row is
    /// not a live, public, free room. Testable without the network.
    static func room(fromCard data: JSONValue) -> LiveRoom? {
        guard data["isLive"].boolValue == true,
              data["isAdult"].boolValue != true,
              data["isPw"].boolValue != true,
              let userID = data["userId"].stringValue, isValidUserID(userID),
              let nickname = data["userNick"].stringValue, !nickname.isEmpty,
              let title = data["title"].stringValue, !title.isEmpty else { return nil }
        return LiveRoom(
            id: "pandalive-\(userID)",
            platform: .pandalive,
            roomID: userID,
            title: title,
            anchorName: nickname,
            anchorAvatarURL: Self.imageURL(imageString(data["userImg"])),
            coverURL: Self.imageURL(imageString(HaoText.firstNonEmpty(
                data["thumbUrl"].stringValue, data["ivsThumbnail"].stringValue))),
            categoryName: data["category"].stringValue,
            viewerCount: data["user"].intValue ?? 0,
            isLive: true
        )
    }

    /// Pure parser for a /v1/live/bj_list row (a BJ profile, live
    /// or offline). Nil for blocked / adult / password profiles.
    /// Testable without the network.
    static func room(fromSearchProfile profile: JSONValue) -> LiveRoom? {
        guard profile["blockService"].boolValue != true,
              let userID = profile["userId"].stringValue, isValidUserID(userID),
              let nickname = profile["userNick"].stringValue, !nickname.isEmpty else { return nil }
        let media = profile["media"]
        guard !media.isNull else {
            return LiveRoom(
                id: "pandalive-\(userID)",
                platform: .pandalive,
                roomID: userID,
                title: nickname,
                anchorName: nickname,
                anchorAvatarURL: Self.imageURL(imageString(profile["thumbUrl"])),
                coverURL: nil,
                categoryName: nil,
                viewerCount: 0,
                isLive: false
            )
        }
        guard media["isAdult"].boolValue != true,
              media["isPw"].boolValue != true else { return nil }
        let isLive = media["isLive"].boolValue == true
        return LiveRoom(
            id: "pandalive-\(userID)",
            platform: .pandalive,
            roomID: userID,
            title: HaoText.firstNonEmpty(media["title"].stringValue, nickname) ?? nickname,
            anchorName: nickname,
            anchorAvatarURL: Self.imageURL(imageString(profile["thumbUrl"])),
            coverURL: Self.imageURL(imageString(HaoText.firstNonEmpty(
                media["thumbUrl"].stringValue, media["ivsThumbnail"].stringValue))),
            categoryName: media["category"].stringValue,
            viewerCount: isLive ? (media["user"].intValue ?? 0) : 0,
            isLive: isLive
        )
    }

    /// onAirType / liveType == "rec" means a rerun.
    static func isRerun(_ media: JSONValue) -> Bool {
        media["onAirType"].stringValue == "rec" || media["liveType"].stringValue == "rec"
    }

    /// PandaLive images live on *.pandalive.co.kr over https;
    /// anything else is not a usable image URL.
    static func imageString(_ value: JSONValue) -> String? {
        imageString(value.stringValue)
    }

    static func imageString(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host.hasSuffix(".pandalive.co.kr") else { return nil }
        return raw
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return PandaLiveDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }
}
