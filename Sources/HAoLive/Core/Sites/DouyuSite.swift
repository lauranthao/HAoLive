// DouyuSite.swift
// HAo Live — real Douyu adapter (anonymous, no login).
// Endpoints verified live from this VM 2026-11-26:
//   categories  GET open.douyucdn.cn/api/RoomApi/game
//   live list   GET open.douyucdn.cn/api/RoomApi/live?limit=N
//   category    GET open.douyucdn.cn/api/RoomApi/live/{cate_id}?offset=&limit=
//   room detail GET open.douyucdn.cn/api/RoomApi/room/{room_id}
// Play URLs — Pure Live's signed route, verified live from this VM
// 2026-11-27 (the old unsigned getH5Play answers error -9
// "时间戳错误" from every network; the signed V1 answers error 0):
//   GET  www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption?did={did}
//        -> {error: 0, data: {key, rand_str, enc_time, enc_data, is_special}}
//   secret = rand_str, repeated enc_time times: secret = MD5(secret + key)
//   auth = MD5(secret + key + salt), salt = "" when is_special == 1,
//        otherwise "{room_id}{tt}"
//   POST www.douyu.com/lapi/live/getH5PlayV1/{room_id}
//        form: enc_data, tt, did, auth, cdn, rate, hevc=0, fa=0, ive=0,
//        ver=Douyu_new, iar=0; Cookie dy_did + acf_did; Origin/Referer.
//        -> {error: 0, data: {rtmp_url, rtmp_live, rtmp_cdn, cdnsWithName}}
//   There is NO hls_url at any rate or CDN: Douyu's web API is
//   FLV-only, and AVPlayer cannot play FLV. The adapter returns the
//   real FLV streams (the player reports them honestly instead of a
//   black screen) until an FLV-capable engine (VLC/mpv) is wired in.
//   Quality labels come from the server's `multirates` list
//   (verified live 2026-11-28, room 24422): 0 原画2K60 (bit
//   20173), 4 蓝光4M, 3 超清, 2 高清 — and NO rate 1 (build 10's
//   "流畅" was invented; a rate-1 request answers rate 2). The
//   numeric `rate` is an opaque request code, not a bitrate, and
//   the server may answer a different rate than requested — the
//   UI shows what was actually served (applied rate), never the
//   requested label.
// Danmaku: raw TCP to openbarrage.douyutv.com:8601 (STT protocol);
// the VM's egress proxy blocks raw TCP, so the channel is verified
// by fixtures only — it runs on the user's phone, not through here.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DouyuSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .douyu
    private let http = HTTPClient.shared

    private static let openBase = "https://open.douyucdn.cn/api/RoomApi"
    private static let webBase = "https://www.douyu.com"

    /// The device id the signing binds to (Pure Live's
    /// generateDeviceId, douyu_utils.dart:188): a per-process
    /// random 32-hex string, used as did and in the dy_did /
    /// acf_did cookies. The fixed "10000…1501" build 10 used is
    /// only a fallback default in older code — the signing and
    /// the cookie must share one did, and a stable process id is
    /// what Pure Live generates when no cookie is stored.
    private static let sessionDeviceID: String = {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }()

    /// Encryption descriptor cache (Pure Live: 5 min, single
    /// in-flight refresh — _maximumCacheAgeSeconds). The
    /// descriptor is per did; the signing binds to it, so a
    /// stale one fails the play call outright.
    private static let encryptionCache = DouyuEncryptionCache()

    private final class DouyuEncryptionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (enc: Encryption, fetchedAt: Date, did: String)?
        private var inFlight: (did: String, task: Task<Encryption, Error>)?

        /// Scoped locking only (withLock): lock.lock() in an async
        /// context is an error in Swift 6 language mode — the lock
        /// is never held across an await.
        func encryption(did: String, forceRefresh: Bool, fetch: @escaping @Sendable () async throws -> Encryption) async throws -> Encryption {
            enum Step { case cached(Encryption); case task(Task<Encryption, Error>) }
            let step: Step = lock.withLock {
                if !forceRefresh,
                   let cached, cached.did == did,
                   Date().timeIntervalSince(cached.fetchedAt) < 300 {
                    return .cached(cached.enc)
                }
                if let inFlight, inFlight.did == did {
                    return .task(inFlight.task)
                }
                let task = Task { try await fetch() }
                inFlight = (did: did, task: task)
                return .task(task)
            }
            switch step {
            case .cached(let enc):
                return enc
            case .task(let task):
                do {
                    let enc = try await task.value
                    lock.withLock {
                        cached = (enc, Date(), did)
                        inFlight = nil
                    }
                    return enc
                } catch {
                    lock.withLock { inFlight = nil }
                    throw error
                }
            }
        }

        func drop() {
            lock.withLock {
                cached = nil
                inFlight = nil
            }
        }
    }

    /// The websec encryption descriptor for one signing session.
    /// expireAt is the descriptor's own expiry (unix seconds) —
    /// Pure Live refuses to sign with a descriptor that dies
    /// within 30 s (isEncryptionKeyUsable).
    struct Encryption {
        var key: String
        var randStr: String
        var encTime: Int
        var encData: String
        var isSpecial: Int
        var expireAt: Int
    }

    // MARK: - Lists

    func categories() async throws -> [LiveCategory] {
        let json = try await http.getJSON("\(Self.openBase)/game")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return Self.categories(fromGameList: json["data"])
    }

    /// Pure parser for the game list. Testable without the network.
    static func categories(fromGameList data: JSONValue) -> [LiveCategory] {
        data.arrayValue.compactMap { item in
            guard let id = item["cate_id"].stringValue,
                  let name = item["game_name"].stringValue, !name.isEmpty else { return nil }
            return LiveCategory(id: "douyu-\(id)", platform: .douyu, name: name, iconName: nil, iconURL: Self.imageURL(item["game_icon"].stringValue))
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        // Offset paging verified live: offset=30 returns a different
        // page than offset=0 (2026-11-27).
        let offset = max(0, page - 1) * 30
        let json = try await http.getJSON("\(Self.openBase)/live?offset=\(offset)&limit=30")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"].arrayValue.map(Self.room(fromListItem:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let cateID = category.id.dropFirst("douyu-".count)
        let offset = max(0, page - 1) * 30
        let json = try await http.getJSON("\(Self.openBase)/live/\(cateID)?offset=\(offset)&limit=30")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"].arrayValue.map(Self.room(fromListItem:))
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    /// Douyu's web search API. The endpoint answers from a real
    /// browser; from this VM it returns a "提示信息" bot page, so the
    /// response shape is parsed defensively and the call is marked
    /// unverified until a device confirms it.
    private func search(keyword: String) async throws -> [LiveRoom] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "\(Self.webBase)/api/search/api/searchRoom?kw=\(encoded)"
        let data = try await http.get(url, headers: ["Referer": "\(Self.webBase)/"])
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        let list = json["data"]["list"].arrayValue
        return list.map(Self.room(fromListItem:))
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let json = try await http.getJSON("\(Self.openBase)/room/\(roomID)")
        guard json["error"].intValue == 0 else { throw LiveSiteError.roomNotFound(roomID) }
        guard let room = Self.room(fromDetail: json["data"]) else { throw LiveSiteError.roomNotFound(roomID) }
        return room
    }

    /// Pure parser for a room detail response. Testable without the network.
    static func room(fromDetail data: JSONValue) -> LiveRoom? {
        guard let id = data["room_id"].stringValue else { return nil }
        return LiveRoom(
            id: "douyu-\(id)",
            platform: .douyu,
            roomID: id,
            title: data["room_name"].stringValue ?? "",
            anchorName: data["owner_name"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(data["avatar"].stringValue),
            coverURL: Self.imageURL(data["room_thumb"].stringValue),
            categoryName: data["cate_name"].stringValue,
            viewerCount: data["online"].intValue ?? data["hn"].intValue ?? 0,
            isLive: data["room_status"].stringValue == "1"
        )
    }

    // MARK: - Play URLs (signed getH5PlayV1, Pure Live's route)
    //
    // Pure Live's douyu_site.dart, in order:
    //   1. Discovery: _requestPlayData(rate: -1) — one call returns
    //      multirates (the advertised quality list, in the server's
    //      order) + cdnsWithName + rtmp_cdn.
    //   2. Per (rate, CDN): _requestPlayData(rate, cdn), sequential
    //      (Pure Live resolves one CDN after another; the old
    //      parallel 15-call burst took 10 s on this VM, sequential
    //      is ~1 s for the selected tier). URLs are grouped by
    //      APPLIED rate; the cohort whose applied rate equals the
    //      requested rate wins, else the first acknowledged cohort
    //      in platform order.
    //   3. CDN order: rtmp_cdn first, then cdnsWithName in order,
    //      scdn-* last.
    //   4. did: per-process random 32-hex (sessionDeviceID), shared
    //      by the signing and the dy_did / acf_did cookies.
    //   5. Headers: the full request set on the encryption call AND
    //      the play calls (build 10 sent NO headers on encryption
    //      and no User-Agent on play).
    //   6. Encryption descriptor cached 5 min, single in-flight
    //      refresh.
    //
    // One-shot API note: Pure Live resolves only the SELECTED
    // quality's CDNs (getPlayUrls is per-quality, ~1 s to first
    // play); HAoLive's playURLs returns the full list for the
    // picker, so it resolves every quality's CDNs (~3 s). The
    // order is best-first and sequential, as Pure Live does it.

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let roomID = room.roomID
        let did = Self.sessionDeviceID
        // Discovery (rate -1): qualities + CDNs in one call.
        // streamStatus 0 on THIS answer only means the room is on
        // air but pushing no stream (wzgrx douyu_api.dart
        // qualities(): StreamUnavailable) — the URLs it still
        // carries 404 on every CDN, so fail here with a clear
        // message instead of handing dead URLs to the player. A
        // per-rate answer may say 0 for a room that played once
        // (S09-24422-r2-hw-h5), so never judge those.
        guard let discovery = try? await requestPlayData(roomID: roomID, rate: -1, cdn: "", did: did) else { return [] }
        if discovery["data"]["streamStatus"].intValue == 0 {
            throw LiveSiteError.message("主播暂未开播")
        }
        let cdns = Self.cdnCodes(fromPlayResponse: discovery)
        let qualities = Self.qualities(fromPlayData: discovery["data"])
        let headers = PlaybackHeaders.headers(platform: .douyu, roomID: roomID, cookie: "dy_did=\(did); acf_did=\(did)")
        var streams: [PlayStream] = []
        var seenURLs: Set<String> = []
        var seenQualityLines: Set<String> = []
        // Best quality first, CDNs sequentially, applied-rate grouping.
        for quality in qualities {
            var byAppliedRate: [(applied: Int, urls: [PlayStream])] = []
            for cdn in cdns {
                guard let json = try? await requestPlayData(roomID: roomID, rate: quality.rate, cdn: cdn, did: did),
                      let stream = Self.stream(fromPlayResponse: json, quality: quality.label, line: cdn.isEmpty ? "主线路" : cdn) else { continue }
                let applied = Self.appliedRate(fromPlayResponse: json) ?? quality.rate
                if let index = byAppliedRate.firstIndex(where: { $0.applied == applied }) {
                    byAppliedRate[index].urls.append(stream)
                } else {
                    byAppliedRate.append((applied: applied, urls: [stream]))
                }
            }
            // Prefer the cohort the server served for the requested
            // rate; else the first acknowledged cohort (platform order).
            guard let cohort = byAppliedRate.first(where: { $0.applied == quality.rate }) ?? byAppliedRate.first else { continue }
            // Label with the APPLIED quality name, not the requested
            // one: the server may answer rate 4 (蓝光4M) for a
            // rate-0 (原画) request.
            let appliedLabel = Self.label(forRate: cohort.applied, advertised: qualities) ?? quality.label
            for stream in cohort.urls {
                guard seenURLs.insert(stream.url.absoluteString).inserted else { continue }
                // Two request rates can serve the same (quality,
                // line) with different signatures — same file, same
                // line. Keep the first; the picker shows one line.
                guard seenQualityLines.insert("\(appliedLabel)|\(stream.line)").inserted else { continue }
                var stream = stream
                stream.quality = appliedLabel
                stream.headers = headers
                streams.append(stream)
            }
        }
        return streams
    }

    /// One signed getH5PlayV1 call (Pure Live's _requestPlayData):
    /// 2 attempts; a failure drops the encryption cache so the
    /// retry signs with a fresh descriptor (Pure Live's
    /// ensureFreshSession(force: true)).
    private func requestPlayData(roomID: String, rate: Int, cdn: String, did: String) async throws -> JSONValue {
        var lastError: (any Error)?
        for attempt in 0..<2 {
            do {
                let enc = try await encryption(did: did, forceRefresh: attempt > 0)
                return try await playV1(roomID: roomID, rate: rate, cdn: cdn, did: did, enc: enc)
            } catch {
                lastError = error
                Self.encryptionCache.drop()
            }
        }
        throw lastError ?? LiveSiteError.invalidResponse
    }

    /// Pure Live's parsePlayQualities: the server's multirates list,
    /// in advertised order; `rate` is an opaque request code,
    /// `name` the server's label. Falls back to a single quality
    /// from the response's own rate when multirates is absent.
    struct DiscoveredQuality: Sendable {
        var rate: Int
        var label: String
    }

    static func qualities(fromPlayData data: JSONValue) -> [DiscoveredQuality] {
        var out: [DiscoveredQuality] = []
        for item in data["multirates"].arrayValue {
            guard let rate = item["rate"].intValue else { continue }
            let name = item["name"].stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !out.contains(where: { $0.rate == rate }) else { continue }
            out.append(DiscoveredQuality(rate: rate, label: name.isEmpty ? fallbackLabel(forRate: rate) : name))
        }
        if out.isEmpty {
            let rate = data["rate"].intValue ?? -1
            out.append(DiscoveredQuality(rate: rate, label: fallbackLabel(forRate: rate)))
        }
        return out
    }

    /// Server-rate -> label when the multirates entry carries no
    /// name. Verified live 2026-11-28 (room 24422): 0 原画, 4
    /// 蓝光4M, 3 超清, 2 高清 — and NO rate 1 (build 10's "流畅"
    /// was invented; a rate-1 request answers rate 2). The
    /// multirates `name` field is authoritative; this is only the
    /// fallback.
    static func fallbackLabel(forRate rate: Int) -> String {
        switch rate {
        case 4: return "蓝光4M"
        case 3: return "超清"
        case 2: return "高清"
        case 0: return "原画"
        default: return "原画"
        }
    }

    static func label(forRate rate: Int, advertised: [DiscoveredQuality]) -> String? {
        advertised.first(where: { $0.rate == rate })?.label ?? fallbackLabel(forRate: rate)
    }

    /// The rate the server actually served (Pure Live's
    /// resolvePlayUrl reads playData['rate']). Nil when the
    /// response carries no numeric rate.
    static func appliedRate(fromPlayResponse json: JSONValue) -> Int? {
        guard let rate = json["data"]["rate"].intValue, rate >= 0 else { return nil }
        return rate
    }

    private func encryption(did: String, forceRefresh: Bool = false) async throws -> Encryption {
        try await Self.encryptionCache.encryption(did: did, forceRefresh: forceRefresh) {
            try await Self.fetchEncryption(did: did)
        }
    }

    private static func fetchEncryption(did: String) async throws -> Encryption {
        let json = try await HTTPClient.shared.getJSON(
            "\(webBase)/wgapi/livenc/liveweb/websec/getEncryption?did=\(did)",
            headers: requestHeaders(roomID: "", did: did)
        )
        guard let enc = encryption(fromJSON: json) else { throw LiveSiteError.invalidResponse }
        return enc
    }

    /// Pure Live's DouyuUtils.requestHeaders: UA Chrome/128
    /// Windows, Accept, Accept-Language, Origin, Referer, Cookie
    /// (dy_did + acf_did). Build 10 sent NO headers on the
    /// encryption call and no User-Agent on the play call.
    private static func requestHeaders(roomID: String, did: String) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "Origin": webBase,
            "Referer": roomID.isEmpty ? "\(webBase)/" : "\(webBase)/\(roomID)",
            "User-Agent": PlaybackHeaders.douyuUA,
            "Cookie": "dy_did=\(did); acf_did=\(did)",
        ]
    }

    /// Pure parser for a getEncryption response. Testable without the network.
    /// Pure Live's isEncryptionKeyUsable (douyu_utils.dart:120-135):
    /// expire_at must outlive the signing call by 30 s, enc_time
    /// 1...16, key/rand_str/enc_data non-empty. A stale descriptor
    /// used to be signed with anyway — the play call then failed
    /// with no streams and no picture.
    static func encryption(fromJSON json: JSONValue) -> Encryption? {
        guard json["error"].intValue == 0 else { return nil }
        let data = json["data"]
        guard let key = data["key"].stringValue, !key.isEmpty,
              let randStr = data["rand_str"].stringValue, !randStr.isEmpty,
              let encTime = data["enc_time"].intValue, (1...16).contains(encTime),
              let encData = data["enc_data"].stringValue, !encData.isEmpty,
              let expireAt = data["expire_at"].intValue,
              expireAt > Int(Date().timeIntervalSince1970) + 30 else { return nil }
        return Encryption(
            key: key,
            randStr: randStr,
            encTime: encTime,
            encData: encData,
            isSpecial: data["is_special"].intValue ?? 0,
            expireAt: expireAt
        )
    }

    /// Pure signing: secret = rand_str, repeated enc_time times
    /// MD5(secret + key); auth = MD5(secret + key + salt), salt is ""
    /// for special rooms, otherwise "{room_id}{timestamp}".
    /// Testable without the network.
    static func auth(key: String, randStr: String, encTime: Int, isSpecial: Int, roomID: String, timestamp: Int) -> String {
        var secret = randStr
        for _ in 0..<encTime {
            secret = MD5.hex(secret + key)
        }
        let salt = isSpecial == 1 ? "" : "\(roomID)\(timestamp)"
        return MD5.hex(secret + key + salt)
    }

    private func playV1(roomID: String, rate: Int, cdn: String, did: String, enc: Encryption) async throws -> JSONValue {
        let tt = Int(Date().timeIntervalSince1970)
        let auth = Self.auth(key: enc.key, randStr: enc.randStr, encTime: enc.encTime, isSpecial: enc.isSpecial, roomID: roomID, timestamp: tt)
        let fields: [String: String] = [
            "enc_data": enc.encData,
            "tt": String(tt),
            "did": did,
            "auth": auth,
            "cdn": cdn,
            "rate": String(rate),
            "hevc": "0",
            "fa": "0",
            "ive": "0",
            "ver": "Douyu_new",
            "iar": "0",
        ]
        return try await http.postFormJSON("\(Self.webBase)/lapi/live/getH5PlayV1/\(roomID)", fields: fields, headers: Self.requestHeaders(roomID: roomID, did: did))
    }

    /// Pure parser for the CDN line codes (Pure Live's parseCdnCodes
    /// + the scdn-last sort in getPlayQualites): cdnsWithName[].cdn,
    /// with the current rtmp_cdn first; [""] when the server lists
    /// none. Testable without the network.
    static func cdnCodes(fromPlayResponse json: JSONValue) -> [String] {
        var codes: [String] = []
        for item in json["data"]["cdnsWithName"].arrayValue {
            if let cdn = item["cdn"].stringValue, !cdn.isEmpty, !codes.contains(cdn) {
                codes.append(cdn)
            }
        }
        if let current = json["data"]["rtmp_cdn"].stringValue, !current.isEmpty, !codes.contains(current) {
            codes.insert(current, at: 0)
        }
        // scdn-* lines last (Pure Live sorts them after the
        // platform CDNs in getPlayQualites).
        codes.sort { a, b in
            if a.hasPrefix("scdn") != b.hasPrefix("scdn") { return !a.hasPrefix("scdn") }
            return false
        }
        return codes.isEmpty ? [""] : codes
    }

    /// Pure parser for one getH5PlayV1 response (Pure Live's
    /// parsePlayUrl — no hls_url branch: Douyu's web API returns
    /// no hls_url at any rate or CDN). Builds the FLV URL from
    /// rtmp_live (complete signed address when present) or
    /// rtmp_url / flv_url + rtmp_live. Testable without the
    /// network. The stream carries its lease: the `expire` query
    /// value is RELATIVE seconds from issuance (Pure Live's
    /// getPlayUrlInvalidAt), so the service can refresh before the
    /// CDN closes the line mid-stream.
    static func stream(fromPlayResponse json: JSONValue, quality: String, line: String) -> PlayStream? {
        guard json["error"].intValue == 0 else { return nil }
        let data = json["data"]
        guard var urlString = Self.playURL(fromPlayData: data) else { return nil }
        // Pure Live: 5-minute ws lines (expire=300&fcdn=ws) die
        // mid-stream; appending expire=0 makes the CDN issue its
        // default lifetime instead.
        let patched = urlString.contains("expire=300") && urlString.contains("fcdn=ws")
        if patched {
            urlString += "&expire=0"
        }
        guard let url = URL(string: urlString) else { return nil }
        return PlayStream(url: url, quality: quality, line: line, expiresAt: patched ? nil : Self.expiresAt(fromURLString: urlString))
    }

    /// Lease expiry for a signed URL: `expire` is relative seconds
    /// from issuance (the moment this stream list is built).
    /// Testable without the network.
    static func expiresAt(fromURLString urlString: String) -> Date? {
        guard let components = URLComponents(string: urlString),
              let value = components.queryItems?.first(where: { $0.name == "expire" })?.value,
              let seconds = Int(value), seconds > 0 else { return nil }
        return Date(timeIntervalSinceNow: TimeInterval(seconds))
    }

    /// Pure parser for the V1 play data: rtmp_live is a complete signed
    /// FLV address when present; otherwise join the CDN base (rtmp_url
    /// / flv_url) with the signed media path. Testable without the network.
    static func playURL(fromPlayData data: JSONValue) -> String? {
        let live = unescapeHTML(data["rtmp_live"].stringValue ?? "")
        if isPlayableURL(live) { return live }
        for baseKey in ["rtmp_url", "flv_url"] {
            let base = unescapeHTML(data[baseKey].stringValue ?? "")
            guard !base.isEmpty, !live.isEmpty else { continue }
            var trimmedBase = base
            while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
            var trimmedLive = live
            while trimmedLive.hasPrefix("/") { trimmedLive.removeFirst() }
            let combined = trimmedBase + "/" + trimmedLive
            if isPlayableURL(combined) { return combined }
        }
        for key in ["player_1", "stream_url", "url"] {
            let value = unescapeHTML(data[key].stringValue ?? "")
            if isPlayableURL(value) { return value }
        }
        let flv = unescapeHTML(data["flv_url"].stringValue ?? "")
        if flv.lowercased().contains(".flv"), isPlayableURL(flv) { return flv }
        return nil
    }

    static func isPlayableURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "rtmp"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    /// The play API sometimes HTML-escapes the signed URL (&amp;).
    static func unescapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
        #if canImport(Network)
        return DouyuDanmaku.stream(roomID: roomID)
        #else
        return AsyncStream { $0.finish() }
        #endif
    }

    // MARK: - Mapping helpers

    /// Pure parser for a list item (recommend / category / search).
    /// Testable without the network.
    static func room(fromListItem item: JSONValue) -> LiveRoom {
        let roomID = item["room_id"].stringValue ?? ""
        return LiveRoom(
            id: "douyu-\(roomID)",
            platform: .douyu,
            roomID: roomID,
            title: item["room_name"].stringValue ?? "",
            anchorName: item["nickname"].stringValue ?? item["owner_name"].stringValue ?? "",
            anchorAvatarURL: Self.imageURL(item["avatar"].stringValue),
            coverURL: Self.imageURL(HaoText.firstNonEmpty(item["room_src"].stringValue, item["room_thumb"].stringValue)),
            categoryName: item["cate_name"].stringValue,
            viewerCount: item["online"].intValue ?? item["hn"].intValue ?? 0,
            isLive: true
        )
    }
}

/// Minimal MD5 (RFC 1321) in pure Swift — no CryptoKit dependency, so
/// the signing chain is testable on Linux too. Verified against Python
/// hashlib in the harness.
enum MD5 {
    static func hex(_ string: String) -> String {
        hex(Array(string.utf8))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in digest(bytes) {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return out
    }

    static func digest(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(input.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in 0..<8 {
            message.append(UInt8((bitLength >> (8 * i)) & 0xff))
        }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        let shifts: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]
        let table: [UInt32] = [
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
            0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
            0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
            0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
            0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
            0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
            0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
            0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
            0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
            0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
            0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
            0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
            0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
            0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
            0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
        ]

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                m[i] = UInt32(message[o])
                    | (UInt32(message[o + 1]) << 8)
                    | (UInt32(message[o + 2]) << 16)
                    | (UInt32(message[o + 3]) << 24)
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d); g = i
                case 16..<32:
                    f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d; g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d); g = (7 * i) % 16
                }
                let temp = d
                d = c
                c = b
                b = b &+ rotateLeft(a &+ f &+ table[i] &+ m[g], by: shifts[i])
                a = temp
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var out = [UInt8]()
        for v in [a0, b0, c0, d0] {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    private static func rotateLeft(_ x: UInt32, by n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
