// DouyinABogus.swift
// HAo Live — Douyin a_bogus request signing, ported from Pure Live
// (lib/shared/platforms/douyin/abogus.dart, lib/shared/platforms/douyin/
// douyin_request_params.dart, douyin_utils.dart). Pure Live signs its
// Douyin web requests with a_bogus; without it the category-rooms
// endpoint (and the recommend feed) returns nothing. The port is
// byte-faithful: the same SM3 (see SM3.swift), the same 256-entry
// table, the same RC4 + base64 steps. Randomness and the timestamp
// are injectable so the port can be cross-checked against a Python
// transliteration of the same Dart source on fixed inputs.
//
// The a_bogus value itself is a request signature, not a secret key:
// Douyin's web client computes it in the open (the algorithm ships in
// the page's JS); Pure Live reimplemented it in Dart, we reimplement
// it in Swift. Nothing here is copied from Douyin's own code.

import Foundation

/// The a_bogus signer. One instance per request (Pure Live creates a
/// fresh ABogus per URL build).
struct ABogus {
    /// DouyinRequestParams.kDefaultUserAgent — Pure Live's
    /// DouyinUtils passes this explicitly when constructing ABogus
    /// (the ABogus class default is an older Chrome 130 + Edg string
    /// that the request path never uses).
    static let defaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    let aid: Int
    let pageId: Int
    let userAgent: String

    init(aid: Int = 6383, pageId: Int = 0, userAgent: String = defaultUserAgent) {
        self.aid = aid
        self.pageId = pageId
        self.userAgent = userAgent
    }

    /// Signs `query` (the part after `?`, without any a_bogus) and
    /// returns the full query with `&a_bogus=...` appended.
    /// `timestampMs`, `randomBytes` and `fingerprint` are injectable
    /// for testing; production callers leave them nil.
    func signedQuery(_ query: String, body: String = "", timestampMs: Int64? = nil, endTimestampMs: Int64? = nil, randomBytes: [UInt8]? = nil, fingerprint: String? = nil) -> String {
        let start = timestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let crypto = CryptoUtility()
        // Pure Live's uaKey is just [0, 1, 14].
        let uaKey: [UInt8] = [0, 1, 14]
        let array1 = crypto.paramsToArray(.bytes(crypto.paramsToArray(.string(query))))
        let array2 = crypto.paramsToArray(.bytes(crypto.paramsToArray(.string(body))))
        let array3 = crypto.paramsToArray(
            .string(crypto.base64Encode(crypto.rc4Encrypt(uaKey, Array(userAgent.utf8)), alphabetIndex: 1)),
            addSalt: false)
        // Pure Live timestamps start and end separately (usually the
        // same millisecond; end can tick over by 1).
        let end = endTimestampMs ?? timestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)

        let fp = fingerprint ?? BrowserFingerprint.generate()

        var abDir: [Int: Int] = [:]
        abDir[8] = 3
        abDir[18] = 44
        abDir[66] = 0
        abDir[69] = 0
        abDir[70] = 0
        abDir[71] = 0
        abDir[20] = Int((start >> 24) & 0xff)
        abDir[21] = Int((start >> 16) & 0xff)
        abDir[22] = Int((start >> 8) & 0xff)
        abDir[23] = Int(start & 0xff)
        abDir[24] = jsShiftRight(start, 32)
        abDir[25] = jsShiftRight(start, 40)
        // options = [0, 1, 14], each stored little-endian-ish across
        // four slots (see Pure Live; values are all < 256).
        abDir[26] = 0
        abDir[27] = 0
        abDir[28] = 0
        abDir[29] = 0
        abDir[30] = 0
        abDir[31] = 1
        abDir[32] = 0
        abDir[33] = 0
        abDir[34] = 0
        abDir[35] = 0
        abDir[36] = 0
        abDir[37] = 14
        abDir[38] = array1[21]
        abDir[39] = array1[22]
        abDir[40] = array2[21]
        abDir[41] = array2[22]
        abDir[42] = array3[23]
        abDir[43] = array3[24]
        abDir[44] = Int((end >> 24) & 0xff)
        abDir[45] = Int((end >> 16) & 0xff)
        abDir[46] = Int((end >> 8) & 0xff)
        abDir[47] = Int(end & 0xff)
        abDir[48] = 3
        abDir[49] = jsShiftRight(end, 32)
        abDir[50] = jsShiftRight(end, 40)
        abDir[51] = Int((Int64(pageId) >> 24) & 0xff)
        abDir[52] = Int((Int64(pageId) >> 16) & 0xff)
        abDir[53] = Int((Int64(pageId) >> 8) & 0xff)
        abDir[54] = Int(Int64(pageId) & 0xff)
        abDir[55] = pageId
        abDir[56] = aid
        abDir[57] = aid & 0xff
        abDir[58] = (aid >> 8) & 0xff
        abDir[59] = (aid >> 16) & 0xff
        abDir[60] = (aid >> 24) & 0xff
        abDir[64] = fp.count
        abDir[65] = fp.count

        let sortIndex = [18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55,
                         31, 35, 57, 39, 41, 43, 22, 28, 32, 60, 36, 23, 29, 33, 37,
                         44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71]
        let sortIndex2 = [18, 20, 26, 30, 34, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43,
                          22, 28, 32, 36, 23, 29, 33, 37, 44, 45, 46, 47, 48, 49, 50,
                          24, 25, 52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71]
        var sortedValues = sortIndex.map { abDir[$0] ?? 0 }
        var abXor = abDir[sortIndex2[0]] ?? 0
        for i in 1..<sortIndex2.count {
            abXor ^= abDir[sortIndex2[i]] ?? 0
        }
        sortedValues.append(contentsOf: fp.utf8.map { Int($0) })
        sortedValues.append(abXor)

        let transformed = crypto.transformBytes(sortedValues)
        let rand = randomBytes ?? CryptoUtility.generateRandomBytes()
        let abogusBytes = rand + transformed
        let abogus = crypto.abogusEncode(abogusBytes, alphabetIndex: 0)
        return query + "&a_bogus=" + abogus
    }

    /// Dart's JS-style unsigned right shift: (val & 0xFFFFFFFF) >>> n.
    /// Shifting a 32-bit value by >= 32 is always 0.
    private func jsShiftRight(_ val: Int64, _ n: Int) -> Int {
        if n >= 32 { return 0 }
        return Int((UInt32(val & 0xFFFFFFFF)) >> n)
    }
}

/// Browser fingerprint, matching Pure Live's BrowserFingerprintGenerator
/// (browserType "Edge" -> platform "Win32"): a plausible window/screen
/// geometry string, random per call; injectable via ABogus for tests.
enum BrowserFingerprint {
    static func generate() -> String {
        let innerWidth = 1024 + Int.random(in: 0..<897)
        let innerHeight = 768 + Int.random(in: 0..<313)
        let outerWidth = innerWidth + (24 + Int.random(in: 0..<9))
        let outerHeight = innerHeight + (75 + Int.random(in: 0..<16))
        let screenY = [0, 30].randomElement()!
        let sizeWidth = 1024 + Int.random(in: 0..<897)
        let sizeHeight = 768 + Int.random(in: 0..<313)
        let availWidth = 1280 + Int.random(in: 0..<641)
        let availHeight = 800 + Int.random(in: 0..<281)
        return "\(innerWidth)|\(innerHeight)|\(outerWidth)|\(outerHeight)|" +
            "0|\(screenY)|0|0|\(sizeWidth)|\(sizeHeight)|" +
            "\(availWidth)|\(availHeight)|\(innerWidth)|\(innerHeight)|24|24|Win32"
    }
}

/// The byte-level crypto helpers from Pure Live's abogus.dart.
/// Kept as a class because transformBytes evolves its table as it runs
/// (RC4-style); each ABogus call uses a fresh instance, and
/// transformBytes works on a local copy so repeat calls are identical.
final class CryptoUtility {
    static let salt = "cus"
    // Pure Live's ABogus alphabets (CryptoUtility is constructed with
    // these, not the standard base64 alphabet). Index 0 is used for
    // the final a_bogus encoding, index 1 for the UA base64.
    static let character = "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe"
    static let character2 = "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe"

    private static let initialTable: [Int] = [
        121, 243, 55, 234, 103, 36, 47, 228,
        30, 231, 106, 6, 115, 95, 78, 101,
        250, 207, 198, 50, 139, 227, 220, 105,
        97, 143, 34, 28, 194, 215, 18, 100,
        159, 160, 43, 8, 169, 217, 180, 120,
        247, 45, 90, 11, 27, 197, 46, 3,
        84, 72, 5, 68, 62, 56, 221, 75,
        144, 79, 73, 161, 178, 81, 64, 187,
        134, 117, 186, 118, 16, 241, 130, 71,
        89, 147, 122, 129, 65, 40, 88, 150,
        110, 219, 199, 255, 181, 254, 48, 4,
        195, 248, 208, 32, 116, 167, 69, 201,
        17, 124, 125, 104, 96, 83, 80, 127,
        236, 108, 154, 126, 204, 15, 20, 135,
        112, 158, 13, 1, 188, 164, 210, 237,
        222, 98, 212, 77, 253, 42, 170, 202,
        26, 22, 29, 182, 251, 10, 173, 152,
        58, 138, 54, 141, 185, 33, 157, 31,
        252, 132, 233, 235, 102, 196, 191, 223,
        240, 148, 39, 123, 92, 82, 128, 109,
        57, 24, 38, 113, 209, 245, 2, 119,
        153, 229, 189, 214, 230, 174, 232, 63,
        52, 205, 86, 140, 66, 175, 111, 171,
        246, 133, 238, 193, 99, 60, 74, 91,
        225, 51, 76, 37, 145, 211, 166, 151,
        213, 206, 0, 200, 244, 176, 218, 44,
        184, 172, 49, 216, 93, 168, 53, 21,
        183, 41, 67, 85, 224, 155, 226, 242,
        87, 177, 146, 70, 190, 12, 162, 19,
        137, 114, 25, 165, 163, 192, 23, 59,
        9, 94, 179, 107, 35, 7, 142, 131,
        239, 203, 149, 136, 61, 249, 14, 156,
    ]

    init() {}

    /// SM3 digest of a string (UTF-8) or raw bytes.
    func sm3ToArray(_ input: SM3Input) -> [Int] {
        let bytes: [UInt8]
        switch input {
        case .string(let s): bytes = Array(s.utf8)
        case .bytes(let b): bytes = b.map { UInt8($0 & 0xff) }
        }
        return SM3.digest(bytes).map { Int($0) }
    }

    /// SM3, then SM3 again over the digest; appends the "cus" salt to
    /// string inputs when addSalt is true (byte inputs get no salt).
    func paramsToArray(_ param: SM3Input, addSalt: Bool = true) -> [Int] {
        switch param {
        case .string(let s):
            let withSalt = addSalt ? s + Self.salt : s
            return sm3ToArray(.string(withSalt))
        case .bytes:
            return sm3ToArray(param)
        }
    }

    /// The byte-mixing pass over the sorted values (RC4-like; evolves
    /// a local copy of the table, so repeat calls are identical).
    func transformBytes(_ bytes: [Int]) -> [UInt8] {
        var table = Self.initialTable
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var indexB = table[1]
        var initialValue = 0
        var valueE = 0
        for index in 0..<bytes.count {
            var sumInitial: Int
            if index == 0 {
                initialValue = table[indexB]
                sumInitial = indexB + initialValue
                table[1] = initialValue
                table[indexB] = indexB
            } else {
                sumInitial = initialValue + valueE
            }
            let charValue = bytes[index]
            sumInitial %= table.count
            let valueF = table[sumInitial]
            result.append(UInt8((charValue ^ valueF) & 0xff))
            valueE = table[(index + 2) % table.count]
            sumInitial = (indexB + valueE) % table.count
            initialValue = table[sumInitial]
            table[sumInitial] = table[(index + 2) % table.count]
            table[(index + 2) % table.count] = initialValue
            indexB = sumInitial
        }
        return result
    }

    /// RC4 with the given key over the plaintext bytes.
    func rc4Encrypt(_ key: [UInt8], _ plaintext: [UInt8]) -> [UInt8] {
        var s = Array(0..<256)
        var j = 0
        for i in 0..<256 {
            j = (j + s[i] + Int(key[i % key.count])) & 0xff
            s.swapAt(i, j)
        }
        var out: [UInt8] = []
        out.reserveCapacity(plaintext.count)
        var i = 0
        j = 0
        for byte in plaintext {
            i = (i + 1) & 0xff
            j = (j + s[i]) & 0xff
            s.swapAt(i, j)
            out.append(byte ^ UInt8(s[(s[i] + s[j]) & 0xff]))
        }
        return out
    }

    /// Custom base64 over raw bytes with the selected alphabet
    /// (0 = standard +/=, 1 = the shuffled alphabet).
    func base64Encode(_ bytes: [UInt8], alphabetIndex: Int) -> String {
        let alphabet = alphabetIndex == 1 ? Self.character2 : Self.character
        var binary = ""
        binary.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for i in (0..<8).reversed() {
                binary.append(((byte >> i) & 1) == 1 ? "1" : "0")
            }
        }
        let paddingLength = (6 - binary.count % 6) % 6
        binary += String(repeating: "0", count: paddingLength)
        let chars = Array(binary)
        var result = ""
        var i = 0
        while i < chars.count {
            var value = 0
            for k in 0..<6 {
                value = (value << 1) | (chars[i + k] == "1" ? 1 : 0)
            }
            result.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: value)])
            i += 6
        }
        result += String(repeating: "=", count: paddingLength / 2)
        return result
    }

    /// The a_bogus encoding: 3 bytes -> 4 chars from the selected
    /// alphabet, with '=' padding to a multiple of 4.
    func abogusEncode(_ bytes: [UInt8], alphabetIndex: Int) -> String {
        let alphabet = alphabetIndex == 1 ? Self.character2 : Self.character
        let chars = Array(alphabet)
        var result = ""
        var i = 0
        while i < bytes.count {
            let b1 = Int(bytes[i])
            let b2 = i + 1 < bytes.count ? Int(bytes[i + 1]) : 0
            let b3 = i + 2 < bytes.count ? Int(bytes[i + 2]) : 0
            let combined = (b1 << 16) | (b2 << 8) | b3
            result.append(chars[(combined >> 18) & 0x3F])
            result.append(chars[(combined >> 12) & 0x3F])
            if i + 1 < bytes.count {
                result.append(chars[(combined >> 6) & 0x3F])
            } else {
                break
            }
            if i + 2 < bytes.count {
                result.append(chars[combined & 0x3F])
            } else {
                break
            }
            i += 3
        }
        result += String(repeating: "=", count: (4 - result.count % 4) % 4)
        return result
    }

    /// 12 "random" bytes (3 iterations x 4), as in Pure Live.
    static func generateRandomBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(12)
        for _ in 0..<3 {
            let rd = Int.random(in: 0..<10000)
            out.append(UInt8(((rd & 255) & 170) | 1))
            out.append(UInt8(((rd & 255) & 85) | 2))
            out.append(UInt8(((rd >> 8) & 170) | 5))
            out.append(UInt8(((rd >> 8) & 85) | 40))
        }
        return out
    }
}

/// SM3 input: a UTF-8 string or raw bytes (Dart's `dynamic` param).
enum SM3Input {
    case string(String)
    case bytes([Int])
}

/// Douyin request URL building, ported from Pure Live's
/// DouyinUtils.buildRequestUrl: merge the base URL's query with the
/// caller's params (caller order kept), apply the standard overrides,
/// generate a fresh msToken when absent, then sign with a_bogus.
enum DouyinURLSigning {
    private static let msTokenAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789="

    static func msToken(length: Int = 184) -> String {
        let chars = Array(msTokenAlphabet)
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// Percent-encode a query key/value the way Dart's Uri does:
    /// unreserved characters pass through, everything else %XX.
    static func encodeQueryComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.utf8.map { byte in
            if allowed.contains(UnicodeScalar(byte)) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    /// Builds a signed URL. `params` are ordered (key, value) pairs in
    /// the order Pure Live passes them; overrides are applied after.
    static func signedURL(base: String, params: [(String, String)]) -> String {
        var pairs: [(String, String)] = []
        // Keep the base URL's own query params first, in order.
        if let q = base.split(separator: "?", maxSplits: 1).last, base.contains("?") {
            for item in q.split(separator: "&") {
                let kv = item.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    pairs.append((String(kv[0]), String(kv[1])))
                }
            }
        }
        func upsert(_ key: String, _ value: String) {
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[i] = (key, value)
            } else {
                pairs.append((key, value))
            }
        }
        for (k, v) in params { upsert(k, v) }
        upsert("aid", "6383")
        upsert("compress", "gzip")
        upsert("device_platform", "web")
        upsert("browser_language", "zh-CN")
        upsert("browser_platform", "Win32")
        upsert("browser_name", "Edge")
        upsert("browser_version", "125.0.0.0")
        if pairs.first(where: { $0.0 == "msToken" }) == nil {
            pairs.append(("msToken", msToken()))
        }
        let query = pairs.map { "\(encodeQueryComponent($0.0))=\(encodeQueryComponent($0.1))" }.joined(separator: "&")
        let signed = ABogus().signedQuery(query)
        let basePath = base.split(separator: "?", maxSplits: 1).first.map(String.init) ?? base
        return basePath + "?" + signed
    }
}
