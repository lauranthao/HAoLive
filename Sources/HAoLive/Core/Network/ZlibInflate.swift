// ZlibInflate.swift
// HAo Live — raw DEFLATE/zlib/gzip decompression via libz.
// Needed by Bilibili danmaku (zlib frames, protover 2) and Douyin
// danmaku (gzip-compressed protobuf payloads). One code path for iOS
// and Linux: the z_stream struct is laid out by hand (LP64, 112 bytes)
// and the inflate calls are bound with @_silgen_name. The Xcode target
// links libz (OTHER_LDFLAGS -lz); the Linux harness links -lz too.

import Foundation

enum ZlibInflate {
    @_silgen_name("zlibVersion")
    private static func c_zlibVersion() -> UnsafePointer<CChar>

    @_silgen_name("inflateInit2_")
    private static func c_inflateInit2(_ stream: UnsafeMutableRawPointer?, _ windowBits: Int32, _ version: UnsafePointer<CChar>?, _ streamSize: Int32) -> Int32

    @_silgen_name("inflate")
    private static func c_inflate(_ stream: UnsafeMutableRawPointer?) -> Int32

    @_silgen_name("inflateEnd")
    private static func c_inflateEnd(_ stream: UnsafeMutableRawPointer?) -> Int32

    // z_stream field offsets on LP64 (pointers 8 bytes, uInt 4, uLong 8).
    private static let streamSize = 112
    private static let offNextIn = 0
    private static let offAvailIn = 8
    private static let offNextOut = 24
    private static let offAvailOut = 32

    /// Decompress DEFLATE data.
    /// - Parameter windowBits: 15 for zlib-wrapped data, 47 for
    ///   auto-detect (zlib or gzip). Returns nil on corrupt input.
    static func decompress(_ data: Data, windowBits: Int32 = 15) -> Data? {
        guard !data.isEmpty else { return Data() }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: streamSize, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: streamSize)
        guard c_inflateInit2(raw, windowBits, c_zlibVersion(), Int32(streamSize)) == 0 else {
            return nil
        }
        defer { _ = c_inflateEnd(raw) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = 0
        var finished = false
        data.withUnsafeBytes { input in
            guard let base = input.baseAddress else { return }
            raw.storeBytes(of: base, toByteOffset: offNextIn, as: UnsafeRawPointer.self)
            raw.storeBytes(of: UInt32(data.count), toByteOffset: offAvailIn, as: UInt32.self)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBytes { outPtr in
                    raw.storeBytes(of: outPtr.baseAddress!, toByteOffset: offNextOut, as: UnsafeMutableRawPointer.self)
                    raw.storeBytes(of: UInt32(chunkSize), toByteOffset: offAvailOut, as: UInt32.self)
                    status = c_inflate(raw)
                    return chunkSize - Int(raw.load(fromByteOffset: offAvailOut, as: UInt32.self))
                }
                if produced > 0 {
                    output.append(chunk, count: produced)
                }
                let availIn = raw.load(fromByteOffset: offAvailIn, as: UInt32.self)
                // Stop when the stream ends, errors, or no progress is
                // possible (input exhausted with no output produced).
                if status != 0 || (produced == 0 && availIn == 0) {
                    finished = true
                }
            } while !finished
        }
        // Z_OK (0) with all input consumed, or Z_STREAM_END (1).
        return (status == 0 || status == 1) ? output : nil
    }
}
