// RoomSearchMerger.swift
// HAo Live — cross-platform search merge (HAo's own layer).
// Searches run per platform; this merges them: platform order
// (SiteRegistry order), deduped by anchor+title.

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

    /// Merge per-platform results round-robin: first room of each
    /// platform (in platform order), then second of each, and so
    /// on, dropping later duplicates of the same anchor + title.
    ///
    /// Hot's 全部 used the plain platform-ordered merge, so page 1
    /// was the first five platforms' whole pages (Bilibili 30 +
    /// Douyu 30 + Huya 120 + Douyin 20 + Kuaishou 48 = 248 rooms)
    /// before the sixth platform's first room — on the phone that
    /// reads as "全部 only shows the first five platforms".
    /// Interleaved, every platform's first room is inside the
    /// first screenful. A single-platform list is unchanged.
    static func mergeInterleaved(_ perPlatform: [[LiveRoom]]) -> [LiveRoom] {
        var seen = Set<String>()
        var out: [LiveRoom] = []
        var index = 0
        var progressed = true
        while progressed {
            progressed = false
            for list in perPlatform {
                guard index < list.count else { continue }
                progressed = true
                let room = list[index]
                if seen.insert(room.dedupeKey).inserted {
                    out.append(room)
                }
            }
            index += 1
        }
        return out
    }
}
