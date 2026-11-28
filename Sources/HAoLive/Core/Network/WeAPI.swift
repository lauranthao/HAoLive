// WeAPI.swift
// HAo Live — NetEase WeAPI request envelope (LOOK Live / NetEase Cloud
// Music public web format). NOT an account secret: the AES keys/IV and
// the RSA public exponent/modulus are the public browser request
// format shared by the official web bundle (same values as the
// NetEase Cloud Music WeAPI). No login, no account credential.
//
//   params    = AES-128-CBC(PKCS7, key "0123456789abcdef", IV
//               "0102030405060708") of AES-128-CBC(PKCS7, key
//               "0CoJUm6Qyw8W8jud", same IV) of the JSON plaintext.
//   encSecKey = RSA-1024 raw (textbook, no padding) of the reversed
//               "0123456789abcdef" as a big-endian integer, e=65537.
//
// Pure Swift on purpose (same pattern as the MD5 in DouyuSite):
// CryptoKit has no AES-CBC, CommonCrypto is not importable from a
// SwiftPM target on Linux, and the signing chain stays testable in
// the Linux harness. AES verified against the FIPS-197 vector
// (key 000102..0f, plaintext 00112233..ff -> 69c4e0d86a7b0430d8cdb78070b4c55a).

import Foundation

/// NetEase WeAPI envelope (LOOK Live uses it for every request).
enum WeAPI {
    static let nonceKey = "0CoJUm6Qyw8W8jud"
    static let secretKey = "0123456789abcdef"
    static let iv = "0102030405060708"
    static let publicExponentHex = "010001"
    // 1024-bit RSA modulus from the official web bundle (public key).
    static let modulusHex =
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec"
        + "4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813"
        + "cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"

    /// Encrypt a JSON plaintext string into the (params, encSecKey)
    /// form fields. `encSecKey` is deterministic (the RSA input is
    /// the fixed secret key), so it is computed once per process.
    static func encryptPayload(_ jsonString: String) -> (params: String, encSecKey: String) {
        let first = AES128CBC.encryptBase64(Data(jsonString.utf8), key: Array(nonceKey.utf8), iv: Array(iv.utf8))
        let params = AES128CBC.encryptBase64(Data(first.utf8), key: Array(secretKey.utf8), iv: Array(iv.utf8))
        return (params: params, encSecKey: Self.encSecKey)
    }

    /// RSA raw encryption of the reversed secret key. Cached: the
    /// input never changes, so the value is constant per build.
    static let encSecKey: String = {
        let reversed = [UInt8](Array(secretKey.utf8).reversed())
        let message = BigUInt(hexBytes: reversed)
        let exponent = BigUInt(hexString: publicExponentHex)
        let modulus = BigUInt(hexString: modulusHex)
        let encrypted = message.modPow(exponent, modulus: modulus)
        return encrypted.toHex(paddedBytes: 128)
    }()
}

// MARK: - AES-128-CBC (encrypt only)

/// Minimal AES-128 encrypt (FIPS-197) + CBC/PKCS7, pure Swift.
enum AES128CBC {
    static func encryptBase64(_ plaintext: Data, key: [UInt8], iv: [UInt8]) -> String {
        encrypt(plaintext, key: key, iv: iv).base64EncodedString()
    }

    static func encrypt(_ plaintext: Data, key: [UInt8], iv: [UInt8]) -> Data {
        precondition(key.count == 16 && iv.count == 16)
        var bytes = Array(plaintext)
        // PKCS7 pad.
        let pad = 16 - (bytes.count % 16)
        bytes.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        let roundKeys = expandKey(key)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var previous = iv
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            var block = Array(bytes[offset..<offset + 16])
            for i in 0..<16 { block[i] ^= previous[i] }
            let encrypted = encryptBlock(block, roundKeys: roundKeys)
            out.append(contentsOf: encrypted)
            previous = encrypted
        }
        return out
    }

    /// One-block AES-128 encrypt. Testable without the network
    /// (FIPS-197 vector, see the file header).
    static func encryptBlock(_ block: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        precondition(block.count == 16)
        var state = block
        addRoundKey(&state, roundKeys[0])
        for round in 1..<10 {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys[round])
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys[10])
        return state
    }

    static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        var words = [[UInt8]]()
        words.reserveCapacity(44)
        for i in 0..<4 { words.append(Array(key[i * 4..<i * 4 + 4])) }
        for i in 4..<44 {
            var temp = words[i - 1]
            if i % 4 == 0 {
                temp = [sbox[Int(temp[1])] ^ rcon[i / 4 - 1], sbox[Int(temp[2])], sbox[Int(temp[3])], sbox[Int(temp[0])]]
            }
            var word = [UInt8](repeating: 0, count: 4)
            for j in 0..<4 { word[j] = words[i - 4][j] ^ temp[j] }
            words.append(word)
        }
        // Round keys as flat 16-byte arrays.
        return (0...10).map { round in
            var rk = [UInt8]()
            for w in 0..<4 { rk.append(contentsOf: words[round * 4 + w]) }
            return rk
        }
    }

    private static func addRoundKey(_ state: inout [UInt8], _ roundKey: [UInt8]) {
        for i in 0..<16 { state[i] ^= roundKey[i] }
    }

    private static func subBytes(_ state: inout [UInt8]) {
        for i in 0..<16 { state[i] = sbox[Int(state[i])] }
    }

    /// State is column-major: state[r + 4c]. Row r rotates left by r.
    private static func shiftRows(_ state: inout [UInt8]) {
        var next = state
        for r in 0..<4 {
            for c in 0..<4 {
                next[r + 4 * c] = state[r + 4 * ((c + r) % 4)]
            }
        }
        state = next
    }

    private static func mixColumns(_ state: inout [UInt8]) {
        for c in 0..<4 {
            let a0 = state[0 + 4 * c], a1 = state[1 + 4 * c], a2 = state[2 + 4 * c], a3 = state[3 + 4 * c]
            state[0 + 4 * c] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
            state[1 + 4 * c] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
            state[2 + 4 * c] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
            state[3 + 4 * c] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
        }
    }

    private static func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0x00)
    }

    private static let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]

    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]
}

// MARK: - Minimal big unsigned integer (RSA modPow only)

/// Little-endian UInt32 limbs. Only what textbook RSA needs:
/// compare / subtract / shift-left / multiply / mod / modPow.
struct BigUInt: Equatable {
    var limbs: [UInt32] // little-endian, no trailing zero limbs (except [0])

    init(limbs: [UInt32]) {
        var l = limbs
        while l.count > 1 && l.last == 0 { l.removeLast() }
        self.limbs = l
    }

    init(_ value: UInt32) { self.init(limbs: [value]) }

    init(hexString: String) {
        var hex = hexString
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        if hex.count % 2 == 1 { hex = "0" + hex }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(hexBytes: bytes)
    }

    init(hexBytes bytes: [UInt8]) {
        var limbs = [UInt32]()
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var word: UInt32 = 0
            for b in bytes[start..<i] { word = (word << 8) | UInt32(b) }
            limbs.append(word)
            i = start
        }
        self.init(limbs: limbs.isEmpty ? [0] : limbs)
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }

    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func toHex(paddedBytes: Int) -> String {
        // Most-significant limb first; bytes inside a limb big-endian.
        var bytes = [UInt8]()
        for limb in limbs.reversed() {
            bytes.append(UInt8((limb >> 24) & 0xff))
            bytes.append(UInt8((limb >> 16) & 0xff))
            bytes.append(UInt8((limb >> 8) & 0xff))
            bytes.append(UInt8(limb & 0xff))
        }
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        var hex = bytes.map { String(format: "%02x", $0) }.joined()
        let target = paddedBytes * 2
        while hex.count < target { hex = "0" + hex }
        return hex
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        }
        return false
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool { lhs.limbs == rhs.limbs }

    static func > (lhs: BigUInt, rhs: BigUInt) -> Bool { rhs < lhs }

    /// Requires self >= other.
    func subtracting(_ other: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: limbs.count)
        var borrow: Int64 = 0
        for i in 0..<limbs.count {
            let o = i < other.limbs.count ? Int64(other.limbs[i]) : 0
            var diff = Int64(limbs[i]) - o - borrow
            if diff < 0 { diff += 1 << 32; borrow = 1 } else { borrow = 0 }
            result[i] = UInt32(diff)
        }
        return BigUInt(limbs: result)
    }

    func shiftedLeft(_ bits: Int) -> BigUInt {
        guard !isZero && bits > 0 else { return self }
        let wordShift = bits / 32
        let bitShift = bits % 32
        var result = [UInt32](repeating: 0, count: limbs.count + wordShift + 1)
        for i in 0..<limbs.count {
            let value = UInt64(limbs[i]) << bitShift
            result[i + wordShift] |= UInt32(value & 0xffff_ffff)
            result[i + wordShift + 1] |= UInt32(value >> 32)
        }
        return BigUInt(limbs: result)
    }

    func multiplied(by other: BigUInt) -> BigUInt {
        if isZero || other.isZero { return BigUInt(0) }
        var result = [UInt64](repeating: 0, count: limbs.count + other.limbs.count)
        for i in 0..<limbs.count {
            var carry: UInt64 = 0
            for j in 0..<other.limbs.count {
                let sum = result[i + j] + UInt64(limbs[i]) * UInt64(other.limbs[j]) + carry
                result[i + j] = sum & 0xffff_ffff
                carry = sum >> 32
            }
            var k = i + other.limbs.count
            while carry > 0 {
                let sum = result[k] + carry
                result[k] = sum & 0xffff_ffff
                carry = sum >> 32
                k += 1
            }
        }
        return BigUInt(limbs: result.map { UInt32($0) })
    }

    /// Remainder by binary long division (shift-and-subtract).
    func mod(_ modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero)
        var remainder = self
        while !(remainder < modulus) && !remainder.isZero {
            var shift = remainder.bitLength - modulus.bitLength
            var shifted = modulus.shiftedLeft(shift)
            if shifted > remainder {
                shift -= 1
                shifted = modulus.shiftedLeft(shift)
            }
            remainder = remainder.subtracting(shifted)
        }
        return remainder
    }

    /// Binary square-and-multiply. Exponent here is 65537 (17 bits),
    /// so this runs ~17 squares + 2 multiplies.
    func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        var base = self.mod(modulus)
        var exp = exponent
        while !exp.isZero {
            if exp.limbs[0] & 1 == 1 {
                result = result.multiplied(by: base).mod(modulus)
            }
            exp = exp.shiftedRight(1)
            if !exp.isZero {
                base = base.multiplied(by: base).mod(modulus)
            }
        }
        return result
    }

    func shiftedRight(_ bits: Int) -> BigUInt {
        guard bits > 0 else { return self }
        let wordShift = bits / 32
        let bitShift = bits % 32
        if wordShift >= limbs.count { return BigUInt(0) }
        var result = [UInt32](repeating: 0, count: limbs.count - wordShift)
        for i in 0..<(limbs.count - wordShift) {
            var value = UInt64(limbs[i + wordShift]) >> bitShift
            if bitShift > 0 && i + wordShift + 1 < limbs.count {
                value |= UInt64(limbs[i + wordShift + 1]) << (32 - bitShift)
            }
            result[i] = UInt32(value)
        }
        return BigUInt(limbs: result)
    }
}
