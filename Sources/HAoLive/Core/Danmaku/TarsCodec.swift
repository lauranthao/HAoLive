// TarsCodec.swift
// HAo Live — TARS/JCE binary codec (Tencent's TAF protocol, used by
// Huya's danmaku channel). Mirrors the reference TarsGo codec and the
// live Huya server bytes: ints narrow to the smallest fitting width
// (0 is a ZeroTag head only), strings carry a RAW length byte
// (STRING1) or 4-byte BE length (STRING4), vector<byte> is a
// SIMPLE_LIST of BYTE. The reader is liberal: it accepts any int
// width, treats ZeroTag as 0, and skips unknown fields. Foundation-
// only, so the Linux harness can exercise it directly.
//
// NOTE: TarsReader subscripts its Data from 0, so it requires a
// zero-based Data. A Data slice keeps the original indices
// (startIndex != 0) — wrap slices in Data(...) before decoding.

import Foundation

enum TarsType {
    static let byte: UInt8 = 0
    static let short: UInt8 = 1
    static let int: UInt8 = 2
    static let long: UInt8 = 3
    static let float: UInt8 = 4
    static let double: UInt8 = 5
    static let string1: UInt8 = 6
    static let string4: UInt8 = 7
    static let map: UInt8 = 8
    static let list: UInt8 = 9
    static let structBegin: UInt8 = 10
    static let structEnd: UInt8 = 11
    static let zeroTag: UInt8 = 12
    static let simpleList: UInt8 = 13
}

/// JCE writer. Field order is the caller's responsibility; top-level
/// WriteTo writes fields only, with no begin/end markers.
struct TarsWriter {
    private(set) var data = Data()

    mutating func appendRaw(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writeHead(tag: Int, type: UInt8) {
        if tag < 15 {
            data.append(UInt8(tag << 4) | type)
        } else {
            data.append(0xF0 | type)
            data.append(UInt8(tag))
        }
    }

    /// An int is written in the smallest width that fits it; 0 is a
    /// ZeroTag head with no payload at all.
    mutating func writeInt(tag: Int, value: Int64) {
        if value == 0 {
            writeHead(tag: tag, type: TarsType.zeroTag)
        } else if value >= -128 && value <= 127 {
            writeHead(tag: tag, type: TarsType.byte)
            data.append(UInt8(bitPattern: Int8(value)))
        } else if value >= -32_768 && value <= 32_767 {
            writeHead(tag: tag, type: TarsType.short)
            data.appendUInt16BE(UInt16(bitPattern: Int16(value)))
        } else if value >= -2_147_483_648 && value <= 2_147_483_647 {
            writeHead(tag: tag, type: TarsType.int)
            data.appendUInt32BE(UInt32(bitPattern: Int32(value)))
        } else {
            writeHead(tag: tag, type: TarsType.long)
            data.appendUInt64BE(UInt64(bitPattern: value))
        }
    }

    /// false is a ZeroTag head; true is a BYTE 0x01.
    mutating func writeBool(tag: Int, value: Bool) {
        if value {
            writeHead(tag: tag, type: TarsType.byte)
            data.append(1)
        } else {
            writeHead(tag: tag, type: TarsType.zeroTag)
        }
    }

    /// Strings carry a RAW length (one byte for STRING1, four BE bytes
    /// for STRING4) — not a tagged int length.
    mutating func writeString(tag: Int, value: String) {
        let bytes = Data(value.utf8)
        if bytes.count < 256 {
            writeHead(tag: tag, type: TarsType.string1)
            data.append(UInt8(bytes.count))
        } else {
            writeHead(tag: tag, type: TarsType.string4)
            data.appendUInt32BE(UInt32(bytes.count))
        }
        data.append(bytes)
    }

    /// vector<byte>: SIMPLE_LIST head, BYTE element head, tagged int32
    /// length, raw bytes.
    mutating func writeBytes(tag: Int, value: Data) {
        writeHead(tag: tag, type: TarsType.simpleList)
        writeHead(tag: 0, type: TarsType.byte)
        writeInt(tag: 0, value: Int64(value.count))
        data.append(value)
    }

    mutating func writeStructBegin(tag: Int) {
        writeHead(tag: tag, type: TarsType.structBegin)
    }

    mutating func writeStructEnd() {
        data.append(TarsType.structEnd)
    }
}

/// JCE reader. Fields are read in tag order; `readField` scans forward
/// and stops (without consuming the head) at a larger tag, a struct
/// end, or EOF, so a missing field is simply nil.
struct TarsReader {
    let data: Data
    var offset: Int = 0

    var isAtEnd: Bool { offset >= data.count }

    /// Read one head byte. Returns (tag, type), or nil at EOF.
    mutating func readHead() -> (tag: Int, type: UInt8)? {
        guard offset < data.count else { return nil }
        let byte = data[offset]
        offset += 1
        let type = byte & 0x0F
        var tag = Int(byte >> 4)
        if tag == 15 {
            guard offset < data.count else { return nil }
            tag = Int(data[offset])
            offset += 1
        }
        return (tag, type)
    }

    /// Read an int payload of the given wire type (any width accepted).
    mutating func readIntRaw(type: UInt8) -> Int64? {
        switch type {
        case TarsType.zeroTag:
            return 0
        case TarsType.byte:
            guard offset < data.count else { return nil }
            let value = Int8(bitPattern: data[offset])
            offset += 1
            return Int64(value)
        case TarsType.short:
            guard offset + 2 <= data.count else { return nil }
            let value = data.uint16BE(at: offset)
            offset += 2
            return Int64(Int16(bitPattern: value))
        case TarsType.int:
            guard offset + 4 <= data.count else { return nil }
            let value = data.uint32BE(at: offset)
            offset += 4
            return Int64(Int32(bitPattern: value))
        case TarsType.long:
            guard offset + 8 <= data.count else { return nil }
            let value = data.uint64BE(at: offset)
            offset += 8
            return Int64(bitPattern: value)
        default:
            return nil
        }
    }

    /// Skip one value whose head has already been read.
    mutating func skipValue(type: UInt8) -> Bool {
        switch type {
        case TarsType.zeroTag, TarsType.structEnd:
            return true
        case TarsType.byte:
            guard offset + 1 <= data.count else { return false }
            offset += 1
            return true
        case TarsType.short:
            guard offset + 2 <= data.count else { return false }
            offset += 2
            return true
        case TarsType.int, TarsType.float:
            guard offset + 4 <= data.count else { return false }
            offset += 4
            return true
        case TarsType.long, TarsType.double:
            guard offset + 8 <= data.count else { return false }
            offset += 8
            return true
        case TarsType.string1:
            guard offset < data.count else { return false }
            let count = Int(data[offset])
            offset += 1
            guard offset + count <= data.count else { return false }
            offset += count
            return true
        case TarsType.string4:
            guard offset + 4 <= data.count else { return false }
            let count = Int(data.uint32BE(at: offset))
            offset += 4
            guard offset + count <= data.count else { return false }
            offset += count
            return true
        case TarsType.map:
            guard let count = readInt(tag: 0) else { return false }
            for _ in 0..<(2 * count) {
                guard skipOne() else { return false }
            }
            return true
        case TarsType.list:
            guard let count = readInt(tag: 0) else { return false }
            for _ in 0..<count {
                guard skipOne() else { return false }
            }
            return true
        case TarsType.structBegin:
            return skipStructBody()
        case TarsType.simpleList:
            guard let (_, elementType) = readHead(), elementType == TarsType.byte else { return false }
            guard let count = readInt(tag: 0), count >= 0 else { return false }
            guard offset + Int(count) <= data.count else { return false }
            offset += Int(count)
            return true
        default:
            return false
        }
    }

    /// Skip one whole value: read its head, then its payload.
    mutating func skipOne() -> Bool {
        guard let (_, type) = readHead() else { return false }
        return skipValue(type: type)
    }

    /// Skip the body of a struct whose begin head was already consumed:
    /// fields until the matching struct end (nested structs handled).
    mutating func skipStructBody() -> Bool {
        var depth = 1
        while depth > 0 {
            guard let (_, type) = readHead() else { return false }
            if type == TarsType.structBegin {
                depth += 1
            } else if type == TarsType.structEnd {
                depth -= 1
            } else if !skipValue(type: type) {
                return false
            }
        }
        return true
    }

    /// Advance to the field with the given tag and return its wire
    /// type, or nil when the field is absent. Smaller-tagged fields
    /// are skipped; on a larger tag or a struct end the head is put
    /// back so a later read can still find that field.
    mutating func readField(tag target: Int) -> UInt8? {
        while offset < data.count {
            let saved = offset
            guard let (tag, type) = readHead() else { return nil }
            if tag == target { return type }
            if tag > target || type == TarsType.structEnd {
                offset = saved
                return nil
            }
            guard skipValue(type: type) else { return nil }
        }
        return nil
    }

    mutating func readInt(tag: Int) -> Int64? {
        guard let type = readField(tag: tag) else { return nil }
        return readIntRaw(type: type)
    }

    mutating func readBool(tag: Int) -> Bool? {
        guard let type = readField(tag: tag) else { return nil }
        if type == TarsType.zeroTag { return false }
        guard let value = readIntRaw(type: type) else { return nil }
        return value != 0
    }

    mutating func readString(tag: Int) -> String? {
        guard let type = readField(tag: tag) else { return nil }
        switch type {
        case TarsType.string1:
            guard offset < data.count else { return nil }
            let count = Int(data[offset])
            offset += 1
            guard offset + count <= data.count else { return nil }
            let text = String(data: data[offset..<(offset + count)], encoding: .utf8)
            offset += count
            return text
        case TarsType.string4:
            guard offset + 4 <= data.count else { return nil }
            let count = Int(data.uint32BE(at: offset))
            offset += 4
            guard offset + count <= data.count else { return nil }
            let text = String(data: data[offset..<(offset + count)], encoding: .utf8)
            offset += count
            return text
        default:
            return nil
        }
    }

    mutating func readBytes(tag: Int) -> Data? {
        guard let type = readField(tag: tag), type == TarsType.simpleList else { return nil }
        guard let (_, elementType) = readHead(), elementType == TarsType.byte else { return nil }
        guard let count = readInt(tag: 0), count >= 0 else { return nil }
        guard offset + Int(count) <= data.count else { return nil }
        let bytes = data[offset..<(offset + Int(count))]
        offset += Int(count)
        return Data(bytes)
    }

    /// Read a struct field into a sub-reader positioned at the struct
    /// body. The parent's offset is unchanged; call `skipStructBody`
    /// on the parent afterwards to move past the struct.
    mutating func readStruct(tag: Int) -> TarsReader? {
        guard let type = readField(tag: tag), type == TarsType.structBegin else { return nil }
        return TarsReader(data: data, offset: offset)
    }
}
