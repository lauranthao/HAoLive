// BinaryCoding.swift
// HAo Live — big-endian binary helpers (Bilibili danmaku frames) and a
// minimal protobuf reader (Douyin/Kuaishou danmaku). Foundation-only,
// so the Linux harness can exercise the decoders directly.

import Foundation

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt32BE(_ value: Int32) {
        appendUInt32BE(UInt32(bitPattern: value))
    }

    func uint16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func int32BE(at offset: Int) -> Int32 {
        Int32(bitPattern: uint32BE(at: offset))
    }
}

/// Minimal protobuf wire reader: varints and length-delimited fields.
/// Only wire types 0 (varint) and 2 (length-delimited) are needed for
/// the danmaku frames used here; anything else stops the read.
struct ProtoReader {
    let data: Data
    var offset: Int = 0

    var isAtEnd: Bool { offset >= data.count }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while offset < data.count, shift < 64 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// Read one field. Returns (field number, wire type, payload):
    /// varints come back as .varint, length-delimited as .bytes.
    mutating func field() -> (number: Int, value: ProtoFieldValue)? {
        guard let tag = varint() else { return nil }
        let number = Int(tag >> 3)
        let wireType = Int(tag & 0x7)
        switch wireType {
        case 0:
            guard let value = varint() else { return nil }
            return (number, .varint(value))
        case 2:
            guard let length = varint(), length <= UInt64(data.count - offset) else { return nil }
            let bytes = data.subdata(in: offset..<(offset + Int(length)))
            offset += Int(length)
            return (number, .bytes(bytes))
        default:
            return nil
        }
    }

    /// Collect all fields of this message into a dictionary keyed by
    /// field number (last value wins for repeated scalar fields).
    mutating func allFields() -> [Int: ProtoFieldValue] {
        var out: [Int: ProtoFieldValue] = [:]
        while !isAtEnd {
            guard let (number, value) = field() else { break }
            out[number] = value
        }
        return out
    }

    /// All values of one repeated field, in order.
    mutating func repeatedField(_ number: Int) -> [ProtoFieldValue] {
        var out: [ProtoFieldValue] = []
        while !isAtEnd {
            guard let (n, value) = field() else { break }
            if n == number { out.append(value) }
        }
        return out
    }
}

enum ProtoFieldValue {
    case varint(UInt64)
    case bytes(Data)

    var stringValue: String? {
        if case .bytes(let data) = self {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    var dataValue: Data? {
        if case .bytes(let data) = self { return data }
        return nil
    }

    var uintValue: UInt64? {
        if case .varint(let value) = self { return value }
        return nil
    }
}
