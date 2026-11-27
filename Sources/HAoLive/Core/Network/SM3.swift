// SM3.swift
// HAo Live — SM3 hash (GB/T 32905-2016), pure Swift, no CryptoKit
// dependency (Linux test harness has no CryptoKit). Needed by the
// Douyin a_bogus signer (Pure Live's ABogus hashes every parameter
// with SM3, twice). Verified against the standard vectors:
//   SM3("")    = 1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b
//   SM3("abc") = 66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0

import Foundation

/// SM3, as a byte array. Pure functions, no state.
enum SM3 {
    /// 32-byte digest of `message`.
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var msg = message
        let bitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        // SM3 appends the bit length BIG-endian (unlike MD5).
        for i in 0..<8 {
            msg.append(UInt8((bitLength >> (56 - 8 * i)) & 0xff))
        }

        var v: [UInt32] = [
            0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
            0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
        ]

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 68)
            var w1 = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = UInt32(msg[o]) << 24
                    | UInt32(msg[o + 1]) << 16
                    | UInt32(msg[o + 2]) << 8
                    | UInt32(msg[o + 3])
            }
            for j in 16..<68 {
                let p = w[j - 16] ^ w[j - 9] ^ rotateLeft(w[j - 3], by: 15)
                w[j] = p ^ rotateLeft(p, by: 15) ^ rotateLeft(p, by: 23) ^ rotateLeft(w[j - 13], by: 7) ^ w[j - 6]
            }
            for j in 0..<64 {
                w1[j] = w[j] ^ w[j + 4]
            }
            var a = v[0], b = v[1], c = v[2], d = v[3]
            var e = v[4], f = v[5], g = v[6], h = v[7]
            for j in 0..<64 {
                // T_j rotates by j mod 32 (j runs 0...63).
                let ss1 = rotateLeft(rotateLeft(a, by: 12) &+ e &+ rotateLeft(t(j), by: UInt32(j % 32)), by: 7)
                let ss2 = ss1 ^ rotateLeft(a, by: 12)
                let tt1 = ff(j, a, b, c) &+ d &+ ss2 &+ w1[j]
                let tt2 = gg(j, e, f, g) &+ h &+ ss1 &+ w[j]
                d = c
                c = rotateLeft(b, by: 9)
                b = a
                a = tt1
                h = g
                g = rotateLeft(f, by: 19)
                f = e
                e = p0(tt2)
            }
            v[0] ^= a
            v[1] ^= b
            v[2] ^= c
            v[3] ^= d
            v[4] ^= e
            v[5] ^= f
            v[6] ^= g
            v[7] ^= h
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in v {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    /// 32-byte digest of a UTF-8 string.
    static func digest(_ string: String) -> [UInt8] {
        digest(Array(string.utf8))
    }

    /// Lowercase hex digest of a UTF-8 string.
    static func hex(_ string: String) -> String {
        digest(string).map { String(format: "%02x", $0) }.joined()
    }

    private static func rotateLeft(_ x: UInt32, by n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    private static func p0(_ x: UInt32) -> UInt32 {
        x ^ rotateLeft(x, by: 9) ^ rotateLeft(x, by: 17)
    }

    private static func ff(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        j < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z))
    }

    private static func gg(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        j < 16 ? (x ^ y ^ z) : ((x & y) | (~x & z))
    }

    private static func t(_ j: Int) -> UInt32 {
        j < 16 ? 0x79CC4519 : 0x7A879D8A
    }
}
