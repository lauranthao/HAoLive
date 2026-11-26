// PlayQuality.swift
// HAo Live — playable streams (quality + line) and the picker rules.
// Pure Live's rule, re-implemented: a stream list carries several
// qualities and several lines; the UI shows what the platform really
// offers and never invents a quality tier.

import Foundation

/// One playable stream: a quality on a line.
struct PlayStream: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(quality)|\(line)|\(url.absoluteString)" }
    var url: URL
    var quality: String
    var line: String
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
    static func best(streams: [PlayStream], preferredQuality: String?, preferredLine: String?) -> PlayStream? {
        guard !streams.isEmpty else { return nil }
        if let quality = preferredQuality {
            let inQuality = streams.filter { $0.quality == quality }
            if let line = preferredLine, let match = inQuality.first(where: { $0.line == line }) {
                return match
            }
            if let first = inQuality.first {
                return first
            }
        }
        if let line = preferredLine, let match = streams.first(where: { $0.line == line }) {
            return match
        }
        return streams.first
    }
}
