// FlvTag.swift
// HAo Live — FLV tag access + framing, re-implemented from wzgrx/PureLive
// v4 (packages/live_media/lib/src/relay/flv.dart: FlvTag / FlvFramer).
// Adobe FLV specification v10.1 annex E, plus the Enhanced RTMP/FLV
// extension for HEVC/AV1. No platform code here: Foundation only, so the
// Linux harness can exercise it exactly as the app does.
//
// A "tag" is one complete packet as FlvFramer yields it: the 11-byte tag
// header, the payload, and the trailing 4-byte PreviousTagSize. The first
// packet of a stream is the FLV file header (with PreviousTagSize0).

import Foundation

/// FLV tag accessors. Tags are `[UInt8]` so the parser stays free of
/// Foundation types and is trivially testable.
enum FlvTag {
    /// Audio tag type.
    static let audio = 8
    /// Video tag type.
    static let video = 9
    /// Script data (onMetaData) tag type.
    static let script = 18
    /// Tag header length.
    static let headerLength = 11

    /// The tag type (low 5 bits of the first byte).
    static func type(of tag: [UInt8]) -> Int {
        Int(tag[0]) & 0x1f
    }

    /// Payload length from the header.
    static func dataSize(of tag: [UInt8]) -> Int {
        (Int(tag[1]) << 16) | (Int(tag[2]) << 8) | Int(tag[3])
    }

    /// Timestamp in milliseconds (24 bits plus the extension byte).
    static func timestamp(of tag: [UInt8]) -> Int {
        (Int(tag[7]) << 24) | (Int(tag[4]) << 16) | (Int(tag[5]) << 8) | Int(tag[6])
    }

    /// A copy of `tag` with `timestamp` (wrapped to 32 bits).
    static func withTimestamp(_ tag: [UInt8], _ timestamp: Int) -> [UInt8] {
        var copy = tag
        let value = timestamp & 0xffffffff
        copy[4] = UInt8((value >> 16) & 0xff)
        copy[5] = UInt8((value >> 8) & 0xff)
        copy[6] = UInt8(value & 0xff)
        copy[7] = UInt8((value >> 24) & 0xff)
        return copy
    }

    private static func isEnhanced(_ tag: [UInt8]) -> Bool {
        (tag[headerLength] & 0x80) != 0
    }

    private static func frameType(of tag: [UInt8]) -> Int {
        (Int(tag[headerLength]) >> 4) & 0x07
    }

    /// A video decoder configuration: AVC/legacy-HEVC sequence header or
    /// an Enhanced FLV SequenceStart.
    static func isVideoConfig(_ tag: [UInt8]) -> Bool {
        guard type(of: tag) == video, tag.count >= headerLength + 2 + 4 else { return false }
        if isEnhanced(tag) { return (tag[headerLength] & 0x0f) == 0 }
        let codec = tag[headerLength] & 0x0f
        return (codec == 7 || codec == 12) && tag[headerLength + 1] == 0
    }

    /// A video keyframe carrying picture data (not a configuration or
    /// end-of-sequence).
    static func isKeyframe(_ tag: [UInt8]) -> Bool {
        guard type(of: tag) == video, tag.count >= headerLength + 2 + 4,
              frameType(of: tag) == 1 else { return false }
        if isEnhanced(tag) {
            let packetType = tag[headerLength] & 0x0f
            return packetType == 1 || packetType == 3
        }
        let codec = tag[headerLength] & 0x0f
        if codec == 7 || codec == 12 { return tag[headerLength + 1] == 1 }
        return true
    }

    /// An AAC AudioSpecificConfig.
    static func isAudioConfig(_ tag: [UInt8]) -> Bool {
        type(of: tag) == audio
            && tag.count > headerLength + 2 + 4
            && (tag[headerLength] >> 4) == 10
            && tag[headerLength + 1] == 0
    }

    /// Whether two tags carry the same payload (timestamps may differ).
    /// The trailing PreviousTagSize is excluded from the comparison.
    static func samePayload(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in headerLength..<(a.count - 4) {
            if a[i] != b[i] { return false }
        }
        return true
    }

    /// Builds a complete tag with its trailing PreviousTagSize.
    static func build(type: Int, timestamp: Int, data: [UInt8]) -> [UInt8] {
        var tag = [UInt8](repeating: 0, count: headerLength + data.count + 4)
        let size = data.count
        let value = timestamp & 0xffffffff
        tag[0] = UInt8(type)
        tag[1] = UInt8((size >> 16) & 0xff)
        tag[2] = UInt8((size >> 8) & 0xff)
        tag[3] = UInt8(size & 0xff)
        tag[4] = UInt8((value >> 16) & 0xff)
        tag[5] = UInt8((value >> 8) & 0xff)
        tag[6] = UInt8(value & 0xff)
        tag[7] = UInt8((value >> 24) & 0xff)
        tag.replaceSubrange(headerLength..<(headerLength + size), with: data)
        let previous = headerLength + size
        tag[headerLength + size] = UInt8((previous >> 24) & 0xff)
        tag[headerLength + size + 1] = UInt8((previous >> 16) & 0xff)
        tag[headerLength + size + 2] = UInt8((previous >> 8) & 0xff)
        tag[headerLength + size + 3] = UInt8(previous & 0xff)
        return tag
    }

    /// The FLV file header with audio and video flags, followed by
    /// PreviousTagSize0.
    static func fileHeader(audio: Bool = true, video: Bool = true) -> [UInt8] {
        [0x46, 0x4C, 0x56, 1, UInt8((audio ? 4 : 0) | (video ? 1 : 0)), 0, 0, 0, 9, 0, 0, 0, 0]
    }
}

/// Why a stream could not be framed.
enum FlvFramerError: Error, Sendable {
    /// The first bytes are not `FLV`.
    case notFlv
    /// The header's data offset is outside 9...1024.
    case badHeaderLength(Int)
    /// A tag type other than audio / video / script.
    case badTagType(Int)
}

/// Splits an FLV byte stream into packets: first the file header (with
/// PreviousTagSize0), then one complete tag per packet.
final class FlvFramer {
    private var buffer: [UInt8] = [UInt8](repeating: 0, count: 64 * 1024)
    private var start = 0
    private var end = 0
    private var headerDone = false

    init() {}

    /// Bytes received but not yet framed.
    var pending: Int { end - start }

    /// Adds `chunk` and returns every packet it completed. Throws when
    /// the stream is not FLV or a tag type is invalid.
    func add(_ chunk: [UInt8]) throws -> [[UInt8]] {
        append(chunk)
        var packets: [[UInt8]] = []
        while true {
            let available = end - start
            if !headerDone {
                if available < 9 { break }
                guard buffer[start] == 0x46, buffer[start + 1] == 0x4C,
                      buffer[start + 2] == 0x56 else {
                    throw FlvFramerError.notFlv
                }
                let dataOffset = (Int(buffer[start + 5]) << 24)
                    | (Int(buffer[start + 6]) << 16)
                    | (Int(buffer[start + 7]) << 8)
                    | Int(buffer[start + 8])
                guard dataOffset >= 9, dataOffset <= 1024 else {
                    throw FlvFramerError.badHeaderLength(dataOffset)
                }
                if available < dataOffset + 4 { break }
                packets.append(Array(buffer[start..<(start + dataOffset + 4)]))
                start += dataOffset + 4
                headerDone = true
                continue
            }
            if available < FlvTag.headerLength { break }
            let type = Int(buffer[start]) & 0x1f
            guard type == FlvTag.audio || type == FlvTag.video || type == FlvTag.script else {
                throw FlvFramerError.badTagType(type)
            }
            let size = (Int(buffer[start + 1]) << 16)
                | (Int(buffer[start + 2]) << 8)
                | Int(buffer[start + 3])
            let total = FlvTag.headerLength + size + 4
            if available < total { break }
            packets.append(Array(buffer[start..<(start + total)]))
            start += total
        }
        if start == end {
            start = 0
            end = 0
        }
        return packets
    }

    private func append(_ chunk: [UInt8]) {
        let needed = end + chunk.count
        if needed > buffer.count {
            let live = end - start
            if live + chunk.count <= buffer.count && start > 0 {
                buffer.replaceSubrange(0..<live, with: buffer[start..<end])
            } else {
                var capacity = buffer.count
                while capacity < live + chunk.count {
                    capacity *= 2
                }
                var grown = [UInt8](repeating: 0, count: capacity)
                grown.replaceSubrange(0..<live, with: buffer[start..<end])
                buffer = grown
            }
            start = 0
            end = live
        }
        buffer.replaceSubrange(end..<(end + chunk.count), with: chunk)
        end += chunk.count
    }
}
