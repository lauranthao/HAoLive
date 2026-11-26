// HLSPlaylist.swift
// HAo Live — pure HLS (.m3u8) playlist parsing and local index writing.
// Foundation only: no AVFoundation, no UI, so it can be exercised on
// Linux. The recorder uses this to follow a live media playlist and to
// write a local index that AVPlayer can play back offline.
//
// Supported tags: #EXT-X-STREAM-INF (master playlists), #EXTINF,
// #EXT-X-TARGETDURATION, #EXT-X-MEDIA-SEQUENCE, #EXT-X-VERSION,
// #EXT-X-MAP (fMP4 init segment), #EXT-X-DISCONTINUITY, #EXT-X-KEY,
// #EXT-X-ENDLIST. Anything else is ignored.

import Foundation

/// One variant stream listed in a master playlist.
struct HLSVariant: Hashable, Sendable {
    var bandwidth: Int?
    var uri: URL
}

/// One media segment in a media playlist.
struct HLSMediaSegment: Hashable, Sendable {
    var sequence: Int
    var duration: Double
    var uri: URL
    var discontinuity: Bool
}

/// A parsed media (not master) playlist.
struct HLSMediaPlaylist: Sendable {
    var targetDuration: Double
    var mediaSequence: Int
    var version: Int
    var mapURI: URL?
    var segments: [HLSMediaSegment]
    var isEndList: Bool
    var isEncrypted: Bool
}

enum HLSPlaylist: Sendable {
    case master([HLSVariant])
    case media(HLSMediaPlaylist)
}

enum HLSPlaylistParser {
    /// Parse playlist text. Relative URIs are resolved against `baseURL`.
    /// Returns nil when the text is not an HLS playlist at all.
    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { return nil }

        var variants: [HLSVariant] = []
        var targetDuration: Double = 0
        var mediaSequence = 0
        var version = 3
        var mapURI: URL?
        var segments: [HLSMediaSegment] = []
        var isEndList = false
        var isEncrypted = false
        var pendingDuration: Double?
        var pendingDiscontinuity = false
        var pendingBandwidth: Int?

        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = bandwidth(from: line)
                continue
            }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 0
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                continue
            }
            if line.hasPrefix("#EXT-X-VERSION:") {
                version = Int(line.dropFirst("#EXT-X-VERSION:".count)) ?? 3
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = quotedAttribute("URI", in: line),
                   let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    mapURI = resolved
                }
                continue
            }
            if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                if method != "NONE" { isEncrypted = true }
                continue
            }
            if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
                continue
            }
            if line == "#EXT-X-ENDLIST" {
                isEndList = true
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                let rest = line.dropFirst("#EXTINF:".count)
                let durationText = rest.split(separator: ",", maxSplits: 1).first ?? ""
                pendingDuration = Double(durationText)
                continue
            }
            if line.hasPrefix("#") {
                continue
            }
            // A URI line: a variant (after STREAM-INF) or a segment.
            guard let resolved = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            if let bandwidth = pendingBandwidth {
                variants.append(HLSVariant(bandwidth: bandwidth, uri: resolved))
                pendingBandwidth = nil
            } else if let duration = pendingDuration {
                segments.append(HLSMediaSegment(
                    sequence: mediaSequence + segments.count,
                    duration: duration,
                    uri: resolved,
                    discontinuity: pendingDiscontinuity
                ))
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }

        if !variants.isEmpty {
            return .master(variants)
        }
        return .media(HLSMediaPlaylist(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence,
            version: version,
            mapURI: mapURI,
            segments: segments,
            isEndList: isEndList,
            isEncrypted: isEncrypted
        ))
    }

    /// Pick the variant to record from a master playlist: highest
    /// bandwidth, falling back to the first listed variant.
    static func bestVariant(_ variants: [HLSVariant]) -> HLSVariant? {
        variants.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })
    }

    private static func bandwidth(from line: String) -> Int? {
        guard let value = attribute("BANDWIDTH", in: line) else { return nil }
        return Int(value)
    }

    /// Unquoted `KEY=value` attribute from a tag line.
    private static func attribute(_ key: String, in line: String) -> String? {
        let prefix = key + "="
        guard let range = line.range(of: prefix) else { return nil }
        let rest = line[range.upperBound...]
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Quoted `KEY="value"` attribute from a tag line.
    private static func quotedAttribute(_ key: String, in line: String) -> String? {
        let prefix = key + "=\""
        guard let start = line.range(of: prefix)?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return nil }
        return String(line[start..<end])
    }
}

/// Writes the local .m3u8 index for a finished (or in-progress)
/// recording. Segment files live next to the index and are named
/// by the caller; only file names appear in the index, never URLs.
enum LocalHLSIndex {
    struct Entry: Hashable, Sendable {
        var fileName: String
        var duration: Double
        var discontinuity: Bool
    }

    static func text(
        firstSequence: Int,
        targetDuration: Int,
        version: Int,
        mapFileName: String?,
        entries: [Entry],
        ended: Bool
    ) -> String {
        var out: [String] = ["#EXTM3U"]
        out.append("#EXT-X-VERSION:\(max(version, mapFileName == nil ? 3 : 7))")
        out.append("#EXT-X-TARGETDURATION:\(max(targetDuration, 1))")
        out.append("#EXT-X-MEDIA-SEQUENCE:\(firstSequence)")
        if let mapFileName {
            out.append("#EXT-X-MAP:URI=\"\(mapFileName)\"")
        }
        for entry in entries {
            if entry.discontinuity { out.append("#EXT-X-DISCONTINUITY") }
            out.append("#EXTINF:\(String(format: "%.3f", entry.duration)),")
            out.append(entry.fileName)
        }
        if ended { out.append("#EXT-X-ENDLIST") }
        return out.joined(separator: "\n") + "\n"
    }
}
