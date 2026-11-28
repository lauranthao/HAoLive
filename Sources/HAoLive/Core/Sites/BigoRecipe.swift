// BigoRecipe.swift
// HAo Live — Bigo Live's playback recipe: the web token envelope,
// the studio room reader, and the HLS protection transform.
// Pure Live's bigo_token.dart / bigo_api.dart /
// bigo_hls_protection.dart / bigo_input_recipe.dart,
// re-implemented from scratch for HAo Live.
//
// The web token: GET sec.bigo.sg/v1/webjs/t (JSONP, returns a
// timestamp) -> AES-256-CBC encrypt a JSON envelope with a key/IV
// derived by OpenSSL EVP_BytesToKey (MD5) from a website protocol
// constant, base64 it as "Salted__" + salt + ciphertext -> GET
// sec.bigo.sg/v1/webjs/status?data=… (JSONP, returns the token).
// The passphrase below is a WEBSITE PROTOCOL CONSTANT from the
// public web bundle (Pure Live's own comment: "not account
// material") — it identifies no user and unlocks no account. No
// account key or signing secret is used anywhere here.
// The AES is pure Swift (no CryptoKit/CommonCrypto dependency, so
// it also runs in the Linux harness): the S-box is generated from
// GF(2^8) arithmetic, not a copied table. Verified against
// OpenSSL: EVP key/IV identical for a fixed salt, and the FIPS-197
// AES-256 test vector encrypts to 8ea2b7ca516745bfeafc49904b496089.
//
// VM status 2026-11-28 (honest): the token flow was implemented
// exactly per the reference and the crypto cross-checked against
// OpenSSL, but sec.bigo.sg/v1/webjs/status answered
// {"code":1,"info":"invalid!"} on all four attempts from this VM
// (same-callback / fresh-timestamp / cookie variants). Pure Live's
// own machine got a 54-char token in Sept 2026, and their probe
// notes the anonymous studio endpoint has been login-walling rooms
// since Oct 2026 — so the failure may be egress-IP flagging or a
// server-side change, not the construction. Consequence observed
// live: studio metadata still answers (needLogin false, alive 1,
// nick/title filled) but hls_src comes back EMPTY, so playURLs
// honestly returns [] until a valid token yields an hls_src.
// Directory + detail still work; playback is blocked on that step.
//
// The HLS protection: when a Bigo master carries
// #EXT-X-BIGO-WEB-PROTECTION:VERSION=1,SEED=n, the first 376 bytes
// of each segment are XOR-masked (Pure Live's BigoHlsProtection,
// applied in their ffmpeg relay before the bytes reach the
// player). HAoLive applies the same step in LoopbackRelay.openHls
// (LivePlayerService relays every Bigo line through it): the
// transform is implemented here (and is its own inverse), the
// relay calls it per segment; playURLs returns the hls_src with
// needsHlsSegmentRestore so the player knows to relay it.

import Foundation

// MARK: - AES-256-CBC (encrypt only), pure Swift

/// Minimal AES-256 encryption (FIPS-197), encrypt-only, CBC with
/// PKCS#7 padding. The S-box is generated from GF(2^8) arithmetic
/// at first use — no copied tables.
enum AES256CBC {
    /// Encrypt `plaintext` under `key` (32 bytes) with `iv`
    /// (16 bytes), CBC + PKCS#7. Returns nil on bad key/iv sizes.
    static func encrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard key.count == 32, iv.count == 16 else { return nil }
        let sbox = SBox.table
        let roundKeys = expandKey(key, sbox: sbox)
        var padded = plaintext
        let pad = 16 - (plaintext.count % 16)
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        var out: [UInt8] = []
        out.reserveCapacity(padded.count)
        var previous = iv
        for blockStart in stride(from: 0, to: padded.count, by: 16) {
            var block = (0..<16).map { padded[blockStart + $0] ^ previous[$0] }
            encryptBlock(&block, roundKeys: roundKeys, sbox: sbox)
            out.append(contentsOf: block)
            previous = block
        }
        return out
    }

    static func encryptBlock(_ block: inout [UInt8], roundKeys: [[UInt8]], sbox: [UInt8]) {
        addRoundKey(&block, roundKeys[0])
        for round in 1..<14 {
            subBytes(&block, sbox: sbox)
            shiftRows(&block)
            mixColumns(&block)
            addRoundKey(&block, roundKeys[round])
        }
        subBytes(&block, sbox: sbox)
        shiftRows(&block)
        addRoundKey(&block, roundKeys[14])
    }

    static func expandKey(_ key: [UInt8], sbox: [UInt8]) -> [[UInt8]] {
        var words: [[UInt8]] = []
        for i in 0..<8 {
            words.append(Array(key[(i * 4)..<(i * 4 + 4)]))
        }
        let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d]
        for i in 8..<60 {
            var temp = words[i - 1]
            if i % 8 == 0 {
                temp = [sbox[Int(temp[1])] ^ rcon[i / 8 - 1], sbox[Int(temp[2])], sbox[Int(temp[3])], sbox[Int(temp[0])]]
            } else if i % 8 == 4 {
                temp = temp.map { sbox[Int($0)] }
            }
            words.append(zip(words[i - 8], temp).map { $0.0 ^ $0.1 })
        }
        return (0..<15).map { round in
            (0..<4).flatMap { words[round * 4 + $0] }
        }
    }

    static func addRoundKey(_ block: inout [UInt8], _ roundKey: [UInt8]) {
        for i in 0..<16 { block[i] ^= roundKey[i] }
    }

    static func subBytes(_ block: inout [UInt8], sbox: [UInt8]) {
        for i in 0..<16 { block[i] = sbox[Int(block[i])] }
    }

    /// ShiftRows on a column-major state (state[r + 4c]).
    static func shiftRows(_ block: inout [UInt8]) {
        var out = block
        for row in 0..<4 {
            for col in 0..<4 {
                out[row + 4 * col] = block[row + 4 * ((col + row) % 4)]
            }
        }
        block = out
    }

    static func mixColumns(_ block: inout [UInt8]) {
        for col in 0..<4 {
            let i = col * 4
            let a0 = block[i], a1 = block[i + 1], a2 = block[i + 2], a3 = block[i + 3]
            block[i] = gfMul(2, a0) ^ gfMul(3, a1) ^ a2 ^ a3
            block[i + 1] = a0 ^ gfMul(2, a1) ^ gfMul(3, a2) ^ a3
            block[i + 2] = a0 ^ a1 ^ gfMul(2, a2) ^ gfMul(3, a3)
            block[i + 3] = gfMul(3, a0) ^ a1 ^ a2 ^ gfMul(2, a3)
        }
    }

    /// GF(2^8) multiply (poly 0x11b).
    static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, result: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { result ^= a }
            let high = a & 0x80 != 0
            a = a &<< 1
            if high { a ^= 0x1b }
            b >>= 1
        }
        return result
    }

    /// The AES S-box, generated (not copied): s(x) = affine(inv(x)).
    enum SBox {
        static let table: [UInt8] = {
            (0..<256).map { value in
                let byte = UInt8(value)
                var inv: UInt8 = 0
                if byte != 0 {
                    // a^254 in GF(2^8) is the inverse.
                    var result: UInt8 = 1
                    var base = byte
                    var exp = 254
                    while exp > 0 {
                        if exp & 1 != 0 { result = gfMul(result, base) }
                        base = gfMul(base, base)
                        exp >>= 1
                    }
                    inv = result
                }
                var s = inv
                for shift in [1, 2, 3, 4] {
                    s ^= rotateLeft8(inv, by: shift)
                }
                return s ^ 0x63
            }
        }()

        static func rotateLeft8(_ value: UInt8, by shift: Int) -> UInt8 {
            (value &<< shift) | (value >> (8 - shift))
        }
    }
}

// MARK: - Web token (sec.bigo.sg)

/// The Bigo web token envelope (Pure Live's BigoTokenCodec).
enum BigoTokenCodec {
    /// Website protocol constant from the public web bundle — see
    /// the file header. Not an account key, not a secret.
    static let passphrase = "undefinedval0x01"

    static let securityOrigin = "https://sec.bigo.sg/v1/webjs"

    /// Build the `data` parameter for /v1/webjs/status from the
    /// timestamp /v1/webjs/t returned. `salt` / `randomHex` are
    /// injectable for tests; production passes nil (random).
    static func buildData(_ timestamp: String, salt: [UInt8]? = nil, randomHex: String? = nil) -> String? {
        guard timestamp.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else { return nil }
        let actualSalt: [UInt8] = salt ?? (0..<8).map { _ in UInt8.random(in: 0...255) }
        guard actualSalt.count == 8 else { return nil }
        let dr: String
        if let randomHex {
            guard randomHex.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else { return nil }
            dr = randomHex
        } else {
            dr = (0..<32).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
        }
        let payload = "{\"dr\":\"\(dr)\",\"business\":\"bigolive-video\",\"scene\":\"\",\"at_time\":\"\(timestamp)\",\"ver\":\"2.0\"}"
        let (key, iv) = evpBytesToKey(password: Array(passphrase.utf8), salt: actualSalt)
        guard let encrypted = AES256CBC.encrypt(Array(payload.utf8), key: key, iv: iv) else { return nil }
        let blob = Array("Salted__".utf8) + actualSalt + encrypted
        return Data(blob).base64EncodedString()
    }

    /// OpenSSL EVP_BytesToKey (MD5, 1 iteration): key 32 bytes +
    /// IV 16 bytes.
    static func evpBytesToKey(password: [UInt8], salt: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        var output: [UInt8] = []
        var previous: [UInt8] = []
        while output.count < 48 {
            previous = MD5.digest(previous + password + salt)
            output.append(contentsOf: previous)
        }
        return (Array(output[0..<32]), Array(output[32..<48]))
    }

    /// Parse a JSONP body `callback({...});` for `callback`.
    /// Returns nil when the wrapper does not match.
    static func parseJSONP(_ source: String, callback: String) -> JSONValue? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(callback)("
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(");") else { return nil }
        let body = String(trimmed.dropFirst(prefix.count).dropLast(2))
        guard let data = body.data(using: .utf8) else { return nil }
        return JSONValue.parse(data)
    }

    /// The JSONP callback name of a request made now (ref
    /// bigo_api.callbackName: jsonpcallback_<ms>_<µs % 1_000_000>).
    static func callbackName() -> String {
        let microseconds = Int(Date().timeIntervalSince1970 * 1_000_000)
        return "jsonpcallback_\(microseconds / 1_000)_\(microseconds % 1_000_000)"
    }
}

// MARK: - HLS protection

/// Parser + packet-prefix transform for Bigo's public web HLS
/// extension (Pure Live's BigoHlsProtection). Applying
/// transformSegment twice with the same seed restores the source.
enum BigoHlsProtection {
    /// The SEED=… tag of a protected manifest, or nil when the
    /// manifest is unprotected. Throws on a malformed seed.
    /// Ref bigo_api.BigoHlsProtection.seed: the seed is read from
    /// the tag's attribute list, so `VERSION=1,SEED=n` (the form
    /// the site sends today, fixture S04-playlist) works — the old
    /// code required `SEED=` immediately after the colon and
    /// missed it, leaving segments scrambled.
    static func seed(fromManifest manifest: String) throws -> Int? {
        for line in manifest.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("#EXT-X-BIGO-WEB-PROTECTION:") else { continue }
            let attributes = String(trimmed.dropFirst("#EXT-X-BIGO-WEB-PROTECTION:".count))
            for part in attributes.split(separator: ",") {
                let field = part.trimmingCharacters(in: .whitespaces)
                guard field.uppercased().hasPrefix("SEED=") else { continue }
                let valueText = String(field.dropFirst("SEED=".count)).trimmingCharacters(in: .whitespaces)
                guard let value = Int(valueText), value >= 0, value <= 0xFFFF_FFFF else {
                    throw LiveSiteError.invalidResponse
                }
                return value
            }
            throw LiveSiteError.invalidResponse
        }
        return nil
    }

    /// XOR-unmask the first two TS packets' first 16 bytes each
    /// (376 prefix bytes). Throws on a truncated segment.
    static func transformSegment(_ source: [UInt8], seed: Int) throws -> [UInt8] {
        guard seed >= 0, seed <= 0xFFFF_FFFF, source.count >= 376 else {
            throw LiveSiteError.invalidResponse
        }
        var packets = source
        for packet in 0..<2 {
            var state = UInt32(seed) ^ UInt32(truncatingIfNeeded: UInt32(packet + 1) &* 2_654_435_769)
            if state == 0 { state = 1_831_565_813 }
            let packetOffset = packet * 188
            for offset in 0..<16 {
                state = state ^ (state &<< 13)
                state = state ^ (state >> 17)
                state = state ^ (state &<< 5)
                var mask = UInt8(state & 0xFF)
                if mask == 0 { mask = 165 }
                packets[packetOffset + offset] ^= mask
            }
        }
        return packets
    }
}

// MARK: - Studio room (metadata + media lease)

enum BigoAccess {
    case `public`, loginRequired, restricted
}

/// One Bigo studio room (Pure Live's BigoStudioRoom, trimmed to
/// what HAoLive uses). `hls` is nil for gated / offline rooms.
struct BigoStudioRoom {
    let siteID: String
    let canonicalSiteID: String
    let ownerID: Int
    let access: BigoAccess
    let isPassword: Bool
    let isPaid: Bool
    /// Server-reported alive flag; nil when the room is gated
    /// (the flag is meaningless behind the login wall).
    let isAlive: Bool?
    let roomID: String?
    let nickname: String
    let title: String
    let category: String
    /// `roomType` ("1" ends the live; the chat is not opened for
    /// it — ref bigo_api.danmakuArgs).
    let roomType: String
    let avatarURL: String?
    let snapshotURL: String
    let hlsURL: URL?
}

enum BigoRecipe {
    static let origin = "https://ta.bigo.tv/official_website"
    static let webOrigin = "https://www.bigo.tv"

    static let headers: [String: String] = [
        "Origin": webOrigin,
        "Referer": "\(webOrigin)/",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "X-Requested-With": "XMLHttpRequest",
    ]

    /// siteId validity (Pure Live's BigoApi.validateSiteId).
    static func validateSiteID(_ value: String) -> String? {
        value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil ? value : nil
    }

    /// Parse a bigo.tv room link (or a bare site id) into a site id.
    static func parseLinkOrSiteID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 8192 else { return nil }
        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           let host = url.host?.lowercased(),
           // Ref bigo_api.siteIdFromUrl: bigo.tv or any of its
           // subdomains (www, m, ...), default port only, no user
           // info; a fragment is ignored (24-7), not a refusal.
           (host == "bigo.tv" || host.hasSuffix(".bigo.tv")),
           url.user == nil, url.password == nil,
           url.port == nil || url.port == (scheme == "https" ? 443 : 80) {
            let segments = url.pathComponents.filter { $0 != "/" }
            let reserved = ["about", "download", "index", "live", "login", "search", "signup"]
            let candidate: String?
            if segments.count == 1 {
                candidate = segments[0]
            } else if segments.count == 2, segments[0].range(of: #"^[a-zA-Z]{2}$"#, options: .regularExpression) != nil {
                candidate = segments[1]
            } else {
                candidate = nil
            }
            if let candidate, !reserved.contains(candidate.lowercased()) {
                return validateSiteID(candidate)
            }
            return nil
        }
        return validateSiteID(value)
    }

    /// The short-lived web token (two JSONP calls). Throws when
    /// the security endpoint refuses (VM: {"code":1,"info":
    /// "invalid!"}) — the caller must not invent a token.
    static func webToken(http: HTTPClient) async throws -> String {
        let callback1 = BigoTokenCodec.callbackName()
        let timeData = try await http.get(
            "\(BigoTokenCodec.securityOrigin)/t?callback=\(callback1)",
            headers: headers
        )
        guard let timeText = String(data: timeData, encoding: .utf8),
              let timeJSON = BigoTokenCodec.parseJSONP(timeText, callback: callback1),
              timeJSON["code"].intValue == 0,
              let timestamp = timeJSON["time"].stringValue,
              timestamp.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil,
              let data = BigoTokenCodec.buildData(timestamp) else {
            throw LiveSiteError.invalidResponse
        }
        let callback2 = BigoTokenCodec.callbackName()
        let encoded = data.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? data
        let statusData = try await http.get(
            "\(BigoTokenCodec.securityOrigin)/status?callback=\(callback2)&data=\(encoded)",
            headers: headers
        )
        guard let statusText = String(data: statusData, encoding: .utf8),
              let statusJSON = BigoTokenCodec.parseJSONP(statusText, callback: callback2),
              let token = statusJSON["token"].stringValue,
              !token.isEmpty, token.count <= 4096,
              token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw LiveSiteError.message("Bigo 安全校验未通过")
        }
        return token
    }

    /// Read one studio room (token first, then the room call).
    /// Throws when the token flow fails — there is no token-less
    /// fallback: without a token the room call answers with empty
    /// fields (verified live 2026-11-28).
    /// Ref bigo_site._studio: the site sometimes answers a token's
    /// first use with `needLogin` and accepts the same token a
    /// moment later, so a login-gated first answer is asked once
    /// more with the same token; the gate is kept, but the state
    /// comes from the second answer (BigoStudio.gated).
    static func studioRoom(siteID: String, http: HTTPClient) async throws -> BigoStudioRoom {
        guard let siteID = validateSiteID(siteID) else {
            throw LiveSiteError.roomNotFound(siteID)
        }
        let token = try await webToken(http: http)
        let first = try await askStudio(siteID: siteID, token: token, http: http)
        guard first.access == .loginRequired else { return first }
        let again = try await askStudio(siteID: siteID, token: token, http: http)
        guard again.access != .loginRequired else { return first }
        return gated(again)
    }

    /// One getInternalStudioInfo call with a token.
    private static func askStudio(siteID: String, token: String, http: HTTPClient) async throws -> BigoStudioRoom {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        let url = "\(origin)/studio/getInternalStudioInfo?siteId=\(siteID)&verify=&token=\(encoded)"
        let data = try await http.postForm(url, fields: [:], headers: headers)
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        guard let room = parseStudioRoom(json, siteID: siteID) else {
            throw LiveSiteError.invalidResponse
        }
        return room
    }

    /// The login gate of `room` kept, with the state of its second
    /// answer (ref BigoStudio.gated): the playlist is dropped, so
    /// the room still cannot play, but it is no longer shown with
    /// a zeroed state.
    private static func gated(_ room: BigoStudioRoom) -> BigoStudioRoom {
        BigoStudioRoom(
            siteID: room.siteID,
            canonicalSiteID: room.canonicalSiteID,
            ownerID: room.ownerID,
            access: .loginRequired,
            isPassword: room.isPassword,
            isPaid: room.isPaid,
            isAlive: room.isAlive,
            roomID: room.roomID,
            nickname: room.nickname,
            title: room.title,
            category: room.category,
            roomType: room.roomType,
            avatarURL: room.avatarURL,
            snapshotURL: room.snapshotURL,
            hlsURL: nil
        )
    }

    /// Pure parser for getInternalStudioInfo. Returns nil when the
    /// envelope is not a success. Testable without the network.
    static func parseStudioRoom(_ json: JSONValue, siteID: String) -> BigoStudioRoom? {
        guard json["code"].intValue == 0 else { return nil }
        let data = json["data"]
        guard !data.isNull,
              let owner = data["uid"].intValue, owner >= 1 else { return nil }
        let needLogin = data["needLogin"].boolValue ?? false
        let isPassword = data["passRoom"].boolValue ?? false
        let paidText = data["isPaidShow"].stringValue ?? ""
        let isPaid = paidText == "1"
        let access: BigoAccess
        if needLogin {
            access = .loginRequired
        } else if isPassword || isPaid {
            access = .restricted
        } else {
            access = .public
        }
        let aliveValue = data["alive"].intValue
        // Ref bigo_api.studio alive mapping: the login gate hides
        // it (nil); a restricted room that says alive is live
        // (true), otherwise unknown (nil); a public room reports
        // it directly. The old code nulled it for every restricted
        // room, so a live password/paid room read as unknown.
        let isAlive: Bool? = switch access {
        case .loginRequired: nil
        case .restricted: aliveValue == 1 ? true : nil
        case .public: aliveValue == 1
        }
        let rawHLS = data["hls_src"].stringValue ?? ""
        let hls: URL?
        if access == .public, isAlive == true, !rawHLS.isEmpty,
           let uri = URL(string: rawHLS), uri.scheme == "https",
           uri.path.lowercased().hasSuffix(".m3u8") {
            hls = uri
        } else {
            hls = nil
        }
        let rawRoomID = data["roomId"].stringValue ?? ""
        let roomID: String? = (rawRoomID.isEmpty || rawRoomID == "0") ? nil : rawRoomID
        let avatar = picture(data["avatar"].stringValue ?? "")
        let snapshot = picture(data["snapshot"].stringValue ?? "")
        return BigoStudioRoom(
            siteID: siteID,
            canonicalSiteID: validateSiteID(data["clientBigoId"].stringValue ?? "") ?? siteID,
            ownerID: owner,
            access: access,
            isPassword: isPassword,
            isPaid: isPaid,
            isAlive: isAlive,
            roomID: roomID,
            nickname: data["nick_name"].stringValue ?? "",
            title: data["roomTopic"].stringValue ?? "",
            category: data["gameTitle"].stringValue ?? "",
            roomType: data["roomType"].stringValue ?? "",
            avatarURL: avatar.isEmpty ? nil : avatar,
            snapshotURL: snapshot,
            hlsURL: hls
        )
    }

    /// An http(s) picture URL, or "" when unusable.
    static func picture(_ source: String) -> String {
        guard !source.isEmpty,
              let uri = URL(string: source),
              ["http", "https"].contains(uri.scheme ?? ""),
              !(uri.host ?? "").isEmpty,
              uri.user == nil, uri.password == nil, uri.fragment == nil else { return "" }
        return uri.absoluteString
    }
}
