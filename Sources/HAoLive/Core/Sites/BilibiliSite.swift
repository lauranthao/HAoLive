// BilibiliSite.swift
// HAo Live — real Bilibili adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-26:
//   room info   GET api.live.bilibili.com/room/v1/Room/get_info
//   room list   GET api.live.bilibili.com/room/v3/area/getRoomList
//               (sort_type=online; the sort_type_online value returns
//               an empty list — use "online")
//   areas       GET api.live.bilibili.com/room/v1/Area/getList
//   search      GET api.bilibili.com/x/web-interface/search/type
//               (needs Referer: https://search.bilibili.com/ or it
//               answers with an HTML error page)
//   play info   GET api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo
//   danmaku info GET api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo
//               (risk-controlled from this VM: code -352; the adapter
//               falls back to the default danmaku host with an empty
//               token, which the server still accepts for receiving)
//
// Playback rule (Pure Live's "actual effective quality"): anonymous
// requests are silently downgraded — the server answers current_qn
// (250 = 超清 here) even when qn=10000 was asked. Only the quality
// the server actually returned gets a stream; accept_qn entries
// without URLs are never offered. Only HLS streams are returned:
// AVPlayer cannot play FLV.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BilibiliSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .bilibili
    private let http = HTTPClient.shared

    private static let apiBase = "https://api.live.bilibili.com"
    private static let searchReferer = "https://search.bilibili.com/"

    /// qn -> display name, from the play-info g_qn_desc list when
    /// present; this table is the documented fallback.
    private static let qualityNames: [Int: String] = [
        30000: "杜比", 20000: "4K", 15000: "2K", 10000: "原画",
        400: "蓝光", 250: "超清", 150: "高清", 80: "流畅",
    ]

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.apiBase)/room/v1/Area/getList")
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return Self.categories(fromList: json["data"])
    }

    /// Pure parser for the getList data array (parent areas).
    /// Testable without the network.
    static func categories(fromList data: JSONValue) -> [LiveCategory] {
        data.arrayValue.compactMap { area in
            guard let id = area["id"].stringValue,
                  let name = area["name"].stringValue, !name.isEmpty else { return nil }
            // The parent area itself has no pic; its sub-areas do —
            // use the first sub-area's artwork for the parent card.
            let icon = area["list"].arrayValue.first?["pic"].stringValue
            return LiveCategory(id: "bili-\(id)", platform: .bilibili, name: name, iconName: nil, iconURL: Self.imageURL(icon))
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await roomList(parentAreaID: 0, areaID: 0)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await roomList(parentAreaID: 0, areaID: 0, page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        // Category ids are "bili-{parent area id}".
        let parentID = Int(category.id.dropFirst("bili-".count)) ?? 0
        return try await roomList(parentAreaID: parentID, areaID: 0)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let parentID = Int(category.id.dropFirst("bili-".count)) ?? 0
        return try await roomList(parentAreaID: parentID, areaID: 0, page: page)
    }

    private func roomList(parentAreaID: Int, areaID: Int, page: Int = 1) async throws -> [LiveRoom] {
        let url = "\(Self.apiBase)/room/v3/area/getRoomList?platform=web&parent_area_id=\(parentAreaID)&cate_id=0&area_id=\(areaID)&sort_type=online&page=\(page)&page_size=30"
        let json = try await http.getJSON(url)
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]["list"].arrayValue.map(Self.room(fromListItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://api.bilibili.com/x/web-interface/search/type?search_type=live_room&keyword=\(encoded)&page=\(page)&page_size=20"
        let json = try await http.getJSON(url, headers: ["Referer": Self.searchReferer])
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]["result"].arrayValue.map(Self.room(fromSearchRoomItem:))
    }

    /// Pure parser for one live_room search result.
    /// Testable without the network.
    static func room(fromSearchRoomItem item: JSONValue) -> LiveRoom {
        LiveRoom(
            id: "bili-\(item["roomid"].stringValue ?? "")",
            platform: .bilibili,
            roomID: item["roomid"].stringValue ?? "",
            title: HaoText.stripTags(item["title"].stringValue ?? ""),
            anchorName: HaoText.stripTags(item["uname"].stringValue ?? ""),
            anchorAvatarURL: Self.imageURL(item["uface"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(item["cover"].stringValue, item["pic"].stringValue)),
            categoryName: item["cate_name"].stringValue,
            viewerCount: item["online"].intValue ?? 0,
            isLive: item["live_status"].intValue == 1
        )
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchAnchors(keyword: keyword, page: 1)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://api.bilibili.com/x/web-interface/search/type?search_type=live_user&keyword=\(encoded)&page=\(page)&page_size=20"
        let json = try await http.getJSON(url, headers: ["Referer": Self.searchReferer])
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"]["result"].arrayValue.compactMap(Self.room(fromSearchUserItem:))
    }

    /// Pure parser for one live_user search result.
    /// Testable without the network.
    static func room(fromSearchUserItem item: JSONValue) -> LiveRoom? {
        guard let roomID = item["roomid"].stringValue, !roomID.isEmpty else { return nil }
        return LiveRoom(
            id: "bili-\(roomID)",
            platform: .bilibili,
            roomID: roomID,
            title: HaoText.stripTags(item["cate_name"].stringValue ?? ""),
            anchorName: HaoText.stripTags(item["uname"].stringValue ?? ""),
            anchorAvatarURL: Self.imageURL(item["uface"].stringValue),
            coverURL: nil,
            categoryName: item["cate_name"].stringValue,
            viewerCount: 0,
            isLive: item["live_status"].intValue == 1
        )
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let json = try await http.getJSON("\(Self.apiBase)/room/v1/Room/get_info?room_id=\(roomID)")
        guard json["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        guard let room = Self.room(fromInfo: json["data"]) else { throw LiveSiteError.roomNotFound(roomID) }
        return room
    }

    /// Pure parser for a get_info data object. Testable without the network.
    static func room(fromInfo data: JSONValue) -> LiveRoom? {
        guard let id = data["room_id"].stringValue else { return nil }
        return LiveRoom(
            id: "bili-\(id)",
            platform: .bilibili,
            roomID: id,
            title: data["title"].stringValue ?? "",
            anchorName: data["anchor_info"]["base_info"]["uname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(data["anchor_info"]["base_info"]["face"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(data["user_cover"].stringValue, data["keyframe"].stringValue)),
            categoryName: data["area_name"].stringValue,
            viewerCount: data["online"].intValue ?? 0,
            isLive: data["live_status"].intValue == 1
        )
    }

    // MARK: - Play URLs
    //
    // Pure Live's Bilibili route (bilibili_site.dart):
    //   * getPlayQualites: one qn=0 request discovers the accepted
    //     qualities — g_qn_desc names, filtered to qn values at
    //     least one codec actually accepts (accept_qn ∪ current_qn).
    //     The global descriptor list also contains tiers that can
    //     never resolve to a stream.
    //   * getPlayUrls: re-request with the selected qn, then
    //     parsePlayUrlResolution — the requested qn first, then
    //     protocol (http_stream FLV before http_hls), format
    //     (flv > ts > fmp4), codec (avc first), mcdn hosts last;
    //     only the server-acknowledged current_qn cohort is kept.
    //     Bilibili can advertise 10000/400 and still serve 250 for
    //     every request — the UI must show the applied tier, not
    //     the tapped one.
    // Build 10 asked for qn=10000 once, kept only HLS, and kept
    // only the server's current_qn — one tier, HLS-only.

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let roomID = room.roomID
        let headers = PlaybackHeaders.headers(platform: .bilibili, roomID: roomID)
        let discovery = try await requestPlayInfo(roomID: roomID, qn: 0)
        guard discovery["code"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        let data = discovery["data"]
        // Carousel rooms (live_status 2) carry no playurl_info: they
        // loop a recorded video instead of a live stream. Pure Live
        // resolves the video through getRoundPlayVideo + x/player/playurl.
        if data["playurl_info"].isNull, data["live_status"].intValue == 2 {
            return try await carouselStreams(roomID: roomID, headers: headers)
        }
        let playurl = data["playurl_info"]["playurl"]
        guard !playurl.isNull else { return [] } // room offline
        let qualities = Self.qualities(fromPlayInfo: playurl)
        guard !qualities.isEmpty else { return [] }
        var names = Self.qualityNames
        for entry in playurl["g_qn_desc"].arrayValue {
            if let qn = entry["qn"].intValue, let desc = entry["desc"].stringValue {
                names[qn] = desc
            }
        }
        // One request per accepted quality, best first; the applied
        // cohort of each is labelled with the server-acknowledged
        // qn. URLs deduped across tiers (a qn=10000 request that
        // serves 250 yields the same URLs as the qn=250 request).
        var groups: [(qn: Int, streams: [PlayStream])] = []
        var seenURLs: Set<String> = []
        for quality in qualities {
            let json = try await requestPlayInfo(roomID: roomID, qn: quality.qn)
            guard json["code"].intValue == 0 else { continue }
            let info = json["data"]["playurl_info"]["playurl"]
            guard !info.isNull else { continue }
            let resolved = Self.streams(fromPlayInfo: info, requestedQn: quality.qn)
            guard !resolved.urls.isEmpty else { continue }
            let label = names[resolved.appliedQn] ?? "原画"
            var streams: [PlayStream] = []
            for url in resolved.urls {
                guard seenURLs.insert(url.url.absoluteString).inserted else { continue }
                streams.append(PlayStream(
                    url: url.url,
                    quality: label,
                    line: url.line,
                    headers: headers,
                    formatOverride: url.format
                ))
            }
            guard !streams.isEmpty else { continue }
            groups.append((qn: resolved.appliedQn, streams: streams))
        }
        // Best applied tier first (a downgraded request must not
        // outrank the tier it actually served).
        groups.sort { $0.qn > $1.qn }
        return groups.flatMap(\.streams)
    }

    /// Pure Live's _requestPlayInfo: codec 0 (avc) only, dolby 5,
    /// panorama 1, mask 0, no_playurl 0.
    private func requestPlayInfo(roomID: String, qn: Int) async throws -> JSONValue {
        let url = "\(Self.apiBase)/xlive/web-room/v2/index/getRoomPlayInfo?room_id=\(roomID)&protocol=0,1&format=0,1,2&codec=0&qn=\(qn)&platform=web&ptype=8&dolby=5&panorama=1&mask=0&no_playurl=0"
        return try await http.getJSON(url)
    }

    /// Accepted quality (qn, label), best first. Pure parser for
    /// the discovery payload: only qn values at least one codec
    /// accepts (accept_qn) or currently serves (current_qn).
    /// Testable without the network.
    struct BilibiliQuality: Sendable {
        var qn: Int
        var label: String
    }

    static func qualities(fromPlayInfo playurl: JSONValue) -> [BilibiliQuality] {
        var names = qualityNames
        for entry in playurl["g_qn_desc"].arrayValue {
            if let qn = entry["qn"].intValue, let desc = entry["desc"].stringValue {
                names[qn] = desc
            }
        }
        var accepted: Set<Int> = []
        for stream in playurl["stream"].arrayValue {
            for format in stream["format"].arrayValue {
                for codec in format["codec"].arrayValue {
                    for rawQn in codec["accept_qn"].arrayValue {
                        if let qn = rawQn.intValue, qn > 0 { accepted.insert(qn) }
                    }
                    if let current = codec["current_qn"].intValue, current > 0 {
                        accepted.insert(current)
                    }
                }
            }
        }
        return accepted.sorted(by: >).map { qn in
            BilibiliQuality(qn: qn, label: names[qn] ?? "原画")
        }
    }

    /// The video a carousel room is looping, as playable streams.
    private func carouselStreams(roomID: String, headers: [String: String]) async throws -> [PlayStream] {
        let round = try await http.getJSON("\(Self.apiBase)/live/getRoundPlayVideo?room_id=\(roomID)")
        guard let video = Self.roundVideo(fromJSON: round) else { return [] }
        let play = try await http.getJSON(
            "https://api.bilibili.com/x/player/playurl?bvid=\(video.bvid)&cid=\(video.cid)&qn=80&fnval=0&fnver=0&fourk=1&platform=html5&high_quality=1",
            headers: ["Referer": "https://www.bilibili.com/"]
        )
        return Self.videoURLs(fromJSON: play).map {
            PlayStream(url: $0, quality: "轮播", line: "主线路", headers: headers)
        }
    }

    /// Pure parser for a getRoundPlayVideo response: the video being
    /// looped (bvid + cid). Testable without the network.
    static func roundVideo(fromJSON json: JSONValue) -> (bvid: String, cid: Int)? {
        guard json["code"].intValue == 0 else { return nil }
        let data = json["data"]
        guard let bvid = data["bvid"].stringValue, !bvid.isEmpty,
              bvid.hasPrefix("BV"),
              let cid = data["cid"].intValue, cid > 0 else { return nil }
        return (bvid: bvid, cid: cid)
    }

    /// Pure parser for an x/player/playurl response: the video file
    /// URLs (url + backup_url of each durl part), deduped. Testable
    /// without the network.
    static func videoURLs(fromJSON json: JSONValue) -> [URL] {
        guard json["code"].intValue == 0 else { return [] }
        var urls: [URL] = []
        for part in json["data"]["durl"].arrayValue {
            var candidates: [String] = []
            if let url = part["url"].stringValue { candidates.append(url) }
            candidates.append(contentsOf: part["backup_url"].arrayValue.compactMap(\.stringValue))
            for raw in candidates {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("http"), let url = URL(string: trimmed),
                      !urls.contains(url) else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    /// Pure parser for a getRoomPlayInfo payload (Pure Live's
    /// parsePlayUrlResolution): candidates ranked requested-qn
    /// first, then protocol (http_stream FLV before http_hls),
    /// format (flv > ts > fmp4), codec (avc first), mcdn hosts
    /// last, URL string. Only the server-acknowledged current_qn
    /// cohort is kept, deduped. Returns the applied qn with its
    /// URLs (format + line per URL). Testable without the network.
    struct BilibiliURL: Sendable {
        var url: URL
        var format: String
        var line: String
    }

    static func streams(fromPlayInfo playurl: JSONValue, requestedQn: Int) -> (appliedQn: Int, urls: [BilibiliURL]) {
        struct Candidate {
            var url: String
            var currentQn: Int
            var protocolName: String
            var formatName: String
            var codecName: String
            var line: String
        }
        var candidates: [Candidate] = []
        for stream in playurl["stream"].arrayValue {
            let protocolName = stream["protocol_name"].stringValue ?? ""
            for format in stream["format"].arrayValue {
                let formatName = format["format_name"].stringValue ?? ""
                for codec in format["codec"].arrayValue {
                    guard codec["codec_name"].stringValue == "avc"
                            || codec["codec_name"].stringValue == "hevc" else { continue }
                    guard let qn = codec["current_qn"].intValue, qn > 0,
                          let baseURL = codec["base_url"].stringValue, !baseURL.isEmpty else { continue }
                    for urlInfo in codec["url_info"].arrayValue {
                        guard let host = urlInfo["host"].stringValue, !host.isEmpty else { continue }
                        let extra = urlInfo["extra"].stringValue ?? ""
                        let full = host + baseURL + extra
                        guard full.hasPrefix("http") else { continue }
                        candidates.append(Candidate(
                            url: full,
                            currentQn: qn,
                            protocolName: protocolName,
                            formatName: formatName,
                            codecName: codec["codec_name"].stringValue ?? "",
                            line: Self.lineName(from: host)
                        ))
                    }
                }
            }
        }
        func protocolRank(_ value: String) -> Int { value == "http_stream" ? 0 : 1 }
        func formatRank(_ value: String) -> Int {
            switch value {
            case "flv": return 0
            case "ts": return 1
            case "fmp4": return 2
            default: return 3
            }
        }
        func codecRank(_ value: String) -> Int { value == "avc" ? 0 : 1 }
        candidates.sort {
            let aRequested = $0.currentQn == requestedQn, bRequested = $1.currentQn == requestedQn
            if aRequested != bRequested { return aRequested }
            if protocolRank($0.protocolName) != protocolRank($1.protocolName) {
                return protocolRank($0.protocolName) < protocolRank($1.protocolName)
            }
            if formatRank($0.formatName) != formatRank($1.formatName) {
                return formatRank($0.formatName) < formatRank($1.formatName)
            }
            if codecRank($0.codecName) != codecRank($1.codecName) {
                return codecRank($0.codecName) < codecRank($1.codecName)
            }
            let aMcdn = $0.url.contains("mcdn"), bMcdn = $1.url.contains("mcdn")
            if aMcdn != bMcdn { return !aMcdn }
            return $0.url < $1.url
        }
        guard let first = candidates.first else { return (appliedQn: requestedQn, urls: []) }
        let appliedQn = first.currentQn
        var seen: Set<String> = []
        var urls: [BilibiliURL] = []
        for candidate in candidates where candidate.currentQn == appliedQn {
            guard seen.insert(candidate.url).inserted,
                  let url = URL(string: candidate.url) else { continue }
            urls.append(BilibiliURL(
                url: url,
                format: candidate.protocolName == "http_stream" ? "flv" : "hls",
                line: candidate.line
            ))
        }
        return (appliedQn: appliedQn, urls: urls)
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                var host = BilibiliDanmaku.defaultHost
                var token = ""
                // Best effort: the token endpoint is risk-controlled
                // from some networks (-352); fall back to the default
                // host with an empty token, which still receives.
                if let json = try? await http.getJSON(
                    "\(Self.apiBase)/xlive/web-room/v1/index/getDanmuInfo?id=\(roomID)&type=0",
                    headers: ["Referer": "https://live.bilibili.com/\(roomID)"]
                ), json["code"].intValue == 0 {
                    token = json["data"]["token"].stringValue ?? ""
                    if let firstHost = json["data"]["host_list"][0]["host"].stringValue, !firstHost.isEmpty {
                        host = firstHost
                    }
                }
                #if !os(Linux)
                for await item in BilibiliDanmaku.stream(roomID: roomID, token: token, host: host) {
                    continuation.yield(item)
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Mapping helpers

    /// Pure parser for a list item (recommend / category / search).
    /// Testable without the network.
    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let roomID = item["roomid"].stringValue ?? ""
        return LiveRoom(
            id: "bili-\(roomID)",
            platform: .bilibili,
            roomID: roomID,
            title: item["title"].stringValue ?? "",
            anchorName: item["uname"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(item["face"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(item["cover"].stringValue, item["user_cover"].stringValue)),
            categoryName: item["area_name"].stringValue,
            viewerCount: item["online"].intValue ?? 0,
            // The list endpoints only return live rooms, and the
            // items carry no live_status field: missing means live.
            isLive: item["live_status"].intValue != 0
        )
    }

    /// "//i0.hdslb.com/..." -> https URL; nil for empty strings.

    /// "https://d1--ov-gotcha05.bilivideo.com" -> "gotcha05".
    private static func lineName(from host: String) -> String {
        var name = host
        if let schemeRange = name.range(of: "://") {
            name = String(name[schemeRange.upperBound...])
        }
        name = name.split(separator: ".").first.map(String.init) ?? name
        if let dashRange = name.range(of: "--") {
            name = String(name[dashRange.upperBound...])
        }
        if name.hasPrefix("ov-") { name = String(name.dropFirst(3)) }
        return name.isEmpty ? host : name
    }
}
