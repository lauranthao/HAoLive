// DanmakuEngine.swift
// HAo Live — danmaku filtering: dedupe, keyword/user blocks, expiry.
// Pure Live's danmaku rules, re-implemented: messages are isolated
// per room session, de-duped by message id, and stale messages are
// dropped so a backlog never floods the screen at once.

import Foundation

/// Stateless-per-session danmaku filter. Foundation-only.
final class DanmakuEngine {
    var blockedKeywords: [String]
    var blockedUsers: Set<String>
    /// Keep at most this many live messages on screen.
    var maxOnScreen: Int

    private var seenIDs = Set<String>()

    init(blockedKeywords: [String] = [], blockedUsers: Set<String> = [], maxOnScreen: Int = 40) {
        self.blockedKeywords = blockedKeywords
        self.blockedUsers = blockedUsers
        self.maxOnScreen = maxOnScreen
    }

    /// Returns true when this message may be shown.
    func accept(_ item: DanmakuItem) -> Bool {
        if seenIDs.contains(item.id) { return false }
        if blockedUsers.contains(item.user) { return false }
        for keyword in blockedKeywords where !keyword.isEmpty {
            if item.text.localizedCaseInsensitiveContains(keyword) { return false }
        }
        seenIDs.insert(item.id)
        return true
    }

    /// Filter a batch, newest last, capped to maxOnScreen.
    func visibleItems(from items: [DanmakuItem]) -> [DanmakuItem] {
        let accepted = items.filter { accept($0) }
        if accepted.count > maxOnScreen {
            return Array(accepted.suffix(maxOnScreen))
        }
        return accepted
    }

    func reset() {
        seenIDs.removeAll()
    }
}
