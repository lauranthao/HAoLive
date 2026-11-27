// StubSite.swift
// HAo Live — STUB platform adapter (skeleton only, no network).
// Every first-phase platform runs on this stub until its real
// adapter lands in the next leg. Sample rooms are clearly marked
// and are only used to exercise navigation, cards and the room page.

import Foundation

/// Base stub adapter: serves fixed sample rooms for one platform.
/// Real adapters will replace these methods with network calls
/// behind the same LiveSite protocol; the UI does not change.
class StubLiveSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform
    private let sampleAnchors: [String]
    private let sampleCategories: [String]

    init(platform: LivePlatform, sampleAnchors: [String], sampleCategories: [String]) {
        self.platform = platform
        self.sampleAnchors = sampleAnchors
        self.sampleCategories = sampleCategories
    }

    private func sampleRooms(count: Int, keyword: String? = nil) -> [LiveRoom] {
        let anchors = sampleAnchors
        var rooms: [LiveRoom] = []
        for index in 0..<count {
            let anchor = anchors[index % anchors.count]
            let title = "\(anchor)的直播间 \(index + 1)"
            if let keyword, !keyword.isEmpty,
               !title.localizedCaseInsensitiveContains(keyword),
               !anchor.localizedCaseInsensitiveContains(keyword) {
                continue
            }
            rooms.append(LiveRoom(
                id: "\(platform.rawValue)-\(index)",
                platform: platform,
                roomID: "\(1000 + index)",
                title: title,
                anchorName: anchor,
                anchorAvatarURL: nil,
                coverURL: nil,
                categoryName: sampleCategories[index % sampleCategories.count],
                viewerCount: 1200 + index * 357,
                isLive: true
            ))
        }
        return rooms
    }

    func categories() async throws -> [LiveCategory] {
        sampleCategories.enumerated().map { index, name in
            LiveCategory(id: "\(platform.rawValue)-cat-\(index)", platform: platform, name: name, iconName: nil)
        }
    }

    func recommendRooms() async throws -> [LiveRoom] {
        sampleRooms(count: 6)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        sampleRooms(count: 6).filter { $0.categoryName == category.name }
    }

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        sampleRooms(count: 6, keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        sampleRooms(count: 6, keyword: keyword)
    }

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let room = sampleRooms(count: 6).first(where: { $0.roomID == roomID }) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return room
    }

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        // STUB streams: not playable URLs. The player shows the
        // quality + line UI against them; real URLs come with the
        // real adapter. Never present a stub URL as playable.
        []
    }

    func sampleDanmaku(roomID: String) async -> [DanmakuItem] {
        let lines = ["主播好", "来了来了", "这波操作可以", "前排", "哈哈哈", "666", "关注了", "下播了吗", "音质不错", "弹幕护体"]
        return lines.enumerated().map { index, text in
            DanmakuItem(roomID: roomID, user: "观众\(index + 1)", text: text)
        }
    }
}
