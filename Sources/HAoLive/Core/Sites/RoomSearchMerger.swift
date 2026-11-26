// RoomSearchMerger.swift
// HAo Live — cross-platform search merge (HAo's own layer).
// Searches run per platform; this merges them: platform order
// (Bilibili, Douyu, Huya, Douyin, Kuaishou), deduped by anchor+title.

import Foundation

enum RoomSearchMerger {
    /// Merge per-platform results into one list, in platform order,
    /// dropping later duplicates of the same anchor + title.
    static func merge(_ perPlatform: [[LiveRoom]]) -> [LiveRoom] {
        var seen = Set<String>()
        var out: [LiveRoom] = []
        for list in perPlatform {
            for room in list where seen.insert(room.dedupeKey).inserted {
                out.append(room)
            }
        }
        return out
    }
}
