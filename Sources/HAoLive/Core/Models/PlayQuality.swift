// PlayQuality.swift
// HAo Live — playable streams (quality + line) and the picker rules.
// Pure Live's rule, re-implemented: a stream list carries several
// qualities and several lines; the UI shows what the platform really
// offers and never invents a quality tier.

import Foundation

/// One playable stream: a quality on a line.
/// `headers` are the HTTP headers the player must send when opening
/// this stream (Pure Live's PlaybackHeaderResolver: per-platform
/// User-Agent / Origin / Referer / Cookie). AVPlayer cannot send
/// them; libmpv can (http-header-fields). Streams without headers
/// play with the engine default.
struct PlayStream: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(quality)|\(line)|\(url.absoluteString)" }
    var url: URL
    var quality: String
    var line: String
    var headers: [String: String] = [:]
    /// When the CDN closes this signed URL (Douyu's `expire`
    /// query value is relative seconds from issuance — Pure Live's
    /// getPlayUrlInvalidAt). Nil when the URL carries no known
    /// expiry. The service refreshes the stream before this time
    /// instead of letting the picture freeze mid-stream. A `var`
    /// with a default IS a memberwise-init parameter (a `let`
    /// with a default would not be), so existing construction
    /// sites compile unchanged.
    var expiresAt: Date? = nil
    /// Container the platform declared for this URL (Pure Live's
    /// LiveStreamFacts.format). Nil = derive from the URL.
    /// Bilibili's FLV lines need it: their http_stream URLs do
    /// not always end in .flv, and without it AVPlayer would try
    /// them first and the sweep would waste an attempt.
    var formatOverride: String? = nil
    /// This line's HLS segments are masked upstream and must be
    /// restored through the loopback relay before mpv sees them
    /// (Bigo: ref live_media bigoRelayRecipe / BigoHlsProtection).
    /// The player relays such lines via LoopbackRelay.openHls;
    /// every other line plays direct.
    var needsHlsSegmentRestore: Bool = false

    /// Container declared by the URL ("flv" / "hls" / ""), so the
    /// engine does not have to probe for it (Pure Live's
    /// LiveStreamFacts.format, carried in the source metadata).
    var format: String {
        if let override = formatOverride, !override.isEmpty { return override }
        let path = url.path.lowercased()
        if path.hasSuffix(".flv") { return "flv" }
        if path.hasSuffix(".m3u8") { return "hls" }
        if url.scheme?.lowercased() == "rtmp" { return "flv" }
        return ""
    }

    /// FLV / RTMP streams need an FLV-capable engine (mpv / VLC).
    /// AVPlayer cannot play them — the player reports this honestly
    /// instead of showing a black screen. Douyu's web API is FLV-only
    /// (verified live 2026-11-27: signed getH5PlayV1 returns no
    /// hls_url at any rate or CDN).
    var isFLV: Bool {
        format == "flv" || url.scheme?.lowercased() == "rtmp"
    }

    /// ATS blocks plain-http media: upgrade http:// stream URLs to
    /// https:// (all five platforms serve the same stream over https).
    var httpsURL: URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }
}

/// Picker rules over a stream list. Pure functions, no UI.
enum StreamPicker {
    /// Quality names in the order the platform lists them (best first).
    static func qualities(of streams: [PlayStream]) -> [String] {
        var seen: [String] = []
        for stream in streams where !seen.contains(stream.quality) {
            seen.append(stream.quality)
        }
        return seen
    }

    /// Lines available for one quality, in listed order.
    static func lines(of streams: [PlayStream], quality: String) -> [String] {
        var seen: [String] = []
        for stream in streams where stream.quality == quality && !seen.contains(stream.line) {
            seen.append(stream.line)
        }
        return seen
    }

    /// Pick the stream matching the preferred quality + line;
    /// fall back to the first stream of the preferred quality,
    /// then to the first stream overall. Never returns a stream
    /// the platform did not offer.
    ///
    /// Pure Live's default-quality rule (_setDefaultResolution):
    /// the preferred label if offered; otherwise the preference's
    /// POSITION in the canonical ladder, mapped proportionally
    /// onto the available list (ratio fallback) — e.g. prefer
    /// 流畅 but only 原画/超清 exist → the lowest available,
    /// not silently the best.
    static func best(streams: [PlayStream], preferredQuality: String?, preferredLine: String?) -> PlayStream? {
        guard !streams.isEmpty else { return nil }
        if let quality = preferredQuality {
            let inQuality = streams.filter { $0.quality == quality }
            if let line = preferredLine, let match = matchLine(inQuality, preferredLine: line) {
                return match
            }
            if let first = inQuality.first {
                return first
            }
            let qualities = qualities(of: streams)
            let preferLevel = qualityLadder.firstIndex(of: quality) ?? -1
            let preferRatio = Double(max(preferLevel, 0)) / Double(max(qualityLadder.count - 1, 1))
            let targetIndex = min(max(Int((preferRatio * Double(max(qualities.count - 1, 0))).rounded()), 0), max(qualities.count - 1, 0))
            let inTarget = streams.filter { $0.quality == qualities[targetIndex] }
            if let line = preferredLine, let match = matchLine(inTarget, preferredLine: line) {
                return match
            }
            if let first = inTarget.first {
                return first
            }
        }
        if let line = preferredLine, let match = matchLine(streams, preferredLine: line) {
            return match
        }
        return streams.first
    }

    /// Pure Live's canonical quality ladder (player_consts.dart:
    /// resolutions), used only for the ratio fallback in best().
    static let qualityLadder = ["原画", "蓝光8M", "蓝光4M", "超清", "流畅"]

    /// Line match: exact label first; "线路N" means the Nth line
    /// (1-based) in listed order. The settings picker offers
    /// 线路1/2/3, but real line names are CDN codes (ws-h5…), so
    /// an exact match could never hit — the old preference was
    /// dead. The list passed in is already one quality's lines.
    private static func matchLine(_ streams: [PlayStream], preferredLine: String) -> PlayStream? {
        if let exact = streams.first(where: { $0.line == preferredLine }) { return exact }
        guard preferredLine.hasPrefix("线路"),
              let n = Int(preferredLine.dropFirst("线路".count)), n >= 1,
              let quality = streams.first?.quality else { return nil }
        let orderedLines = lines(of: streams, quality: quality)
        guard n <= orderedLines.count else { return nil }
        return streams.first { $0.line == orderedLines[n - 1] }
    }
}
