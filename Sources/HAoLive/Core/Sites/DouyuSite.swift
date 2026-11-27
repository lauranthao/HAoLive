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
//   rate map: 0 原画, 1 流畅, 2 高清, 3 超清.
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

    /// Documented rate -> quality map for getH5PlayV1.
    private static let rateQualities: [(rate: Int, quality: String)] = [
        (0, "原画"), (3, "超清"), (2, "高清"), (1, "流畅"),
    ]

    /// The websec encryption descriptor for one signing session.
    struct Encryption {
        var key: String
        var randStr: String
        var encTime: Int
        var encData: String
        var isSpecial: Int
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
            return LiveCategory(id: "douyu-\(id)", platform: .douyu, name: name, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        let json = try await http.getJSON("\(Self.openBase)/live?limit=30")
        guard json["error"].intValue == 0 else { throw LiveSiteError.invalidResponse }
        return json["data"].arrayValue.map(Self.room(fromListItem:))
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        let cateID = category.id.dropFirst("douyu-".count)
        let json = try await http.getJSON("\(Self.openBase)/live/\(cateID)?offset=0&limit=30")
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
            anchorAvatarURL: URL(string: data["avatar"].stringValue ?? ""),
            coverURL: URL(string: data["room_thumb"].stringValue ?? ""),
            categoryName: data["cate_name"].stringValue,
            viewerCount: data["online"].intValue ?? data["hn"].intValue ?? 0,
            isLive: data["room_status"].stringValue == "1"
        )
    }

    // MARK: - Play URLs (signed getH5PlayV1)

    func playURLs(roomID: String) async throws -> [PlayStream] {
        let did = Self.deviceID()
        guard let enc = try? await encryption(did: did) else { return [] }
        // The first call also lists the CDN codes for the line matrix.
        guard let first = try? await playV1(roomID: roomID, rate: 0, cdn: "", did: did, enc: enc) else { return [] }
        let cdns = Self.cdnCodes(fromPlayResponse: first)
        var streams: [PlayStream] = []
        if let stream = Self.stream(fromPlayResponse: first, quality: "原画", line: "主线路") {
            streams.append(stream)
        }
        // One request per (rate, CDN line), in parallel; tiers the
        // server refuses are skipped, never faked.
        await withTaskGroup(of: PlayStream?.self) { group in
            for (rate, quality) in Self.rateQualities where rate != 0 {
                for cdn in cdns {
                    group.addTask {
                        guard let json = try? await self.playV1(roomID: roomID, rate: rate, cdn: cdn, did: did, enc: enc) else { return nil }
                        return Self.stream(fromPlayResponse: json, quality: quality, line: cdn.isEmpty ? "主线路" : cdn)
                    }
                }
            }
            // Extra CDN lines for the best quality.
            for cdn in cdns where !cdn.isEmpty {
                group.addTask {
                    guard let json = try? await self.playV1(roomID: roomID, rate: 0, cdn: cdn, did: did, enc: enc) else { return nil }
                    return Self.stream(fromPlayResponse: json, quality: "原画", line: cdn)
                }
            }
            for await stream in group {
                if let stream { streams.append(stream) }
            }
        }
        // Best quality first (原画, 超清, 高清, 流畅).
        let order = Self.rateQualities.map(\.quality)
        return streams.sorted { order.firstIndex(of: $0.quality) ?? 99 < order.firstIndex(of: $1.quality) ?? 99 }
    }

    /// The device id the signing binds to. One stable random id,
    /// persisted — Pure Live keeps the same did across calls.
    private static func deviceID() -> String {
        let key = "douyu.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key), saved.count == 32 {
            return saved
        }
        let did = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(did, forKey: key)
        return did
    }

    private func encryption(did: String) async throws -> Encryption {
        let json = try await http.getJSON("\(Self.webBase)/wgapi/livenc/liveweb/websec/getEncryption?did=\(did)")
        guard let enc = Self.encryption(fromJSON: json) else { throw LiveSiteError.invalidResponse }
        return enc
    }

    /// Pure parser for a getEncryption response. Testable without the network.
    static func encryption(fromJSON json: JSONValue) -> Encryption? {
        guard json["error"].intValue == 0 else { return nil }
        let data = json["data"]
        guard let key = data["key"].stringValue, !key.isEmpty,
              let randStr = data["rand_str"].stringValue, !randStr.isEmpty,
              let encTime = data["enc_time"].intValue,
              let encData = data["enc_data"].stringValue, !encData.isEmpty else { return nil }
        return Encryption(
            key: key,
            randStr: randStr,
            encTime: encTime,
            encData: encData,
            isSpecial: data["is_special"].intValue ?? 0
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
        let headers = [
            "Referer": "\(Self.webBase)/\(roomID)",
            "Origin": Self.webBase,
            "Cookie": "dy_did=\(did); acf_did=\(did)",
        ]
        return try await http.postFormJSON("\(Self.webBase)/lapi/live/getH5PlayV1/\(roomID)", fields: fields, headers: headers)
    }

    /// Pure parser for the CDN line codes (Pure Live's parseCdnCodes):
    /// cdnsWithName[].cdn, with the current rtmp_cdn first; [""] when
    /// the server lists none. Testable without the network.
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
        return codes.isEmpty ? [""] : codes
    }

    /// Pure parser for one getH5PlayV1 response. Prefers hls_url when
    /// the server offers it; otherwise builds the FLV URL from
    /// rtmp_url + rtmp_live. Testable without the network.
    static func stream(fromPlayResponse json: JSONValue, quality: String, line: String) -> PlayStream? {
        guard json["error"].intValue == 0 else { return nil }
        let data = json["data"]
        if let hls = data["hls_url"].stringValue, !hls.isEmpty, let url = URL(string: hls) {
            return PlayStream(url: url, quality: quality, line: line)
        }
        guard var urlString = Self.playURL(fromPlayData: data) else { return nil }
        // Pure Live: 5-minute ws lines (expire=300&fcdn=ws) die
        // mid-stream; appending expire=0 makes the CDN issue its
        // default lifetime instead.
        if urlString.contains("expire=300"), urlString.contains("fcdn=ws") {
            urlString += "&expire=0"
        }
        guard let url = URL(string: urlString) else { return nil }
        return PlayStream(url: url, quality: quality, line: line)
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

    func sampleDanmaku(roomID: String) async -> [DanmakuItem] {
        [] // real channel below; never show fake lines as live danmaku
    }

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
            anchorAvatarURL: URL(string: item["avatar"].stringValue ?? ""),
            coverURL: URL(string: HaoText.firstNonEmpty(item["room_src"].stringValue, item["room_thumb"].stringValue) ?? ""),
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
