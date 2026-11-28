// SteamDanmaku.swift
// HAo Live — Steam Broadcast chat by polling the chat log windows.
//   GET /broadcast/getbroadcastmpd/?broadcastid=0&steamid=&
//       viewertoken=0&sessionid=            -> broadcastid
//   GET /broadcast/getchatinfo/?steamid=&broadcastid=&viewertoken=0
//       &sessionid=                         -> view_url_template
//   GET view_url_template with {0} replaced by the window number
//       -> {messages:[{msg, persona_name, steamid}],
//            next_request, initial_delay}
// Windows advance on the server's clock (initial_delay +
// next_request - window ms). No login, no secret.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SteamDanmaku {
    private static let origin = "https://steamcommunity.com"

    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                guard let steamID = SteamSite.parseSteamID(roomID) else {
                    continuation.finish()
                    return
                }
                var broadcastID = await broadcastIDFromPlayData(roomID: steamID)
                var failures = 0
                while !Task.isCancelled {
                    do {
                        if broadcastID.isEmpty {
                            guard let resolved = await resolveBroadcastID(steamID: steamID) else {
                                throw LiveSiteError.invalidResponse
                            }
                            broadcastID = resolved
                        }
                        guard let template = await chatTemplate(steamID: steamID, broadcastID: broadcastID) else {
                            broadcastID = ""
                            throw LiveSiteError.invalidResponse
                        }
                        try await readWindows(template: template, steamID: steamID, roomID: roomID, continuation: continuation)
                        failures = 0
                    } catch {
                        if Task.isCancelled { break }
                        failures += 1
                        if failures >= 8 {
                            broadcastID = ""
                            failures = 0
                        }
                        let wait = min(1 << min(failures, 3), 8)
                        try? await Task.sleep(for: .seconds(wait))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// broadcastId carried in the room's playDataJSON (from the
    /// detail call), so the danmaku loop can skip one round-trip.
    private static func broadcastIDFromPlayData(roomID: String) async -> String {
        guard let detail = try? await SteamSite().roomDetail(roomID: roomID),
              let payload = detail.playDataJSON,
              let data = payload.data(using: .utf8),
              let json = JSONValue.parse(data),
              let id = json["broadcastId"].stringValue, !id.isEmpty, id != "0" else { return "" }
        return id
    }

    private static func roomHeaders(steamID: String) -> [String: String] {
        [
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Referer": "\(origin)/broadcast/watch/\(steamID)",
            "X-Requested-With": "XMLHttpRequest",
        ]
    }

    private static func resolveBroadcastID(steamID: String) async -> String? {
        let url = "\(origin)/broadcast/getbroadcastmpd/?broadcastid=0&steamid=\(steamID)&viewertoken=0&sessionid="
        guard let json = try? await HTTPClient.shared.getJSON(url, headers: roomHeaders(steamID: steamID)),
              let id = json["broadcastid"].stringValue, !id.isEmpty, id != "0" else { return nil }
        return id
    }

    private static func chatTemplate(steamID: String, broadcastID: String) async -> String? {
        let url = "\(origin)/broadcast/getchatinfo/?steamid=\(steamID)&broadcastid=\(broadcastID)&viewertoken=0&sessionid="
        guard let json = try? await HTTPClient.shared.getJSON(url, headers: roomHeaders(steamID: steamID)),
              let template = json["view_url_template"].stringValue,
              !template.isEmpty, isAcceptableChatURL(template) else { return nil }
        return template
    }

    static func isAcceptableChatURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        if host.hasPrefix("steambroadcast") && host.hasSuffix(".akamaized.net") { return true }
        for domain in ["steamcommunity.com", "steamcontent.com", "steamserver.net", "steamstatic.com"] {
            if host == domain || host.hasSuffix("." + domain) { return true }
        }
        return false
    }

    private static func readWindows(template: String, steamID: String, roomID: String, continuation: AsyncStream<DanmakuItem>.Continuation) async throws {
        var window = 0
        guard var answer = await fetchWindow(template: template, window: window, steamID: steamID, roomID: roomID) else {
            throw LiveSiteError.invalidResponse
        }
        var clock = Date()
        var initialDelay = answer.initialDelayMs
        var next = answer.nextRequest
        guard next > 0 else { throw LiveSiteError.invalidResponse }
        var nudgeMs = 0
        var failures = 0
        while !Task.isCancelled {
            let due = clock.addingTimeInterval(TimeInterval(initialDelay + (next - window) + nudgeMs) / 1000)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Task.isCancelled { return }
            guard let fresh = await fetchWindow(template: template, window: next, steamID: steamID, roomID: roomID) else {
                failures += 1
                nudgeMs = min(nudgeMs + 10, 1000)
                if failures >= 8 { throw LiveSiteError.invalidResponse }
                continue
            }
            failures = 0
            nudgeMs = 0
            for item in fresh.messages { continuation.yield(item) }
            window = next
            if fresh.initialDelayMs > 0 {
                clock = Date()
                initialDelay = fresh.initialDelayMs
            }
            guard fresh.nextRequest > window else { throw LiveSiteError.invalidResponse }
            next = fresh.nextRequest
            answer = fresh
        }
    }

    struct ChatWindow {
        var messages: [DanmakuItem]
        var nextRequest: Int
        var initialDelayMs: Int
    }

    /// One chat window: template {0} -> window number.
    static func fetchWindow(template: String, window: Int, steamID: String, roomID: String) async -> ChatWindow? {
        let url = template.replacingOccurrences(of: "{0}", with: "\(window)")
        guard let json = try? await HTTPClient.shared.getJSON(url, headers: [
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Origin": origin,
            "Referer": "\(origin)/broadcast/watch/\(steamID)",
        ]) else { return nil }
        var messages: [DanmakuItem] = []
        for row in json["messages"].arrayValue {
            guard let text = row["msg"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let name = row["persona_name"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(DanmakuItem(
                roomID: roomID,
                user: (name?.isEmpty == false) ? name! : "Steam 用户",
                text: text
            ))
        }
        return ChatWindow(
            messages: messages,
            nextRequest: json["next_request"].intValue ?? 0,
            initialDelayMs: json["initial_delay"].intValue ?? 0
        )
    }
}
