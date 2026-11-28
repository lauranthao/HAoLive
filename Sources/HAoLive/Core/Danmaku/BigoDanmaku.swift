// BigoDanmaku.swift
// HAo Live — Bigo Live chat over WebSocket
// (wss://wss.bigolive.tv/live/official/web).
// Pure Live's bigo_danmaku.dart, re-implemented from scratch.
//
// Flow: POST ta.bigo.tv/official_website/studio/getWebSocketLink
// (form deviceId) -> guest {userId, uidToken} -> connect the chat
// WS -> the server sends a challenge (event 79108); answer it
// with an MD5 sign (see _answerChallenge) -> login (event 512279)
// -> on 512535 res 200, enter the room (event 1304) -> on 1304
// the channel is live: request the audience (10776) and ping
// (791) every 10 s. Chat arrives as event 2584, tag 1/2, with
// `content` a base64 JSON {m: text, n: name}.
// Frames are "<event><json>" text (event = 1-7 digits, then a
// JSON object). The socket uses URLSessionWebSocketTask text
// frames directly: Bigo's protocol is text, and the shared
// WebSocketTransport only sends binary (.data) frames.
//
// NOT verified live from this VM: the WS handshake needs a live
// room's guest account (getWebSocketLink itself was verified:
// HTTP 200 with userId + uidToken). The packet builders and the
// frame decoder are pure and testable without the network.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BigoDanmaku {
    static let socketURL = "wss://wss.bigolive.tv/live/official/web"
    static let accountURL = "https://ta.bigo.tv/official_website/studio/getWebSocketLink"
    static let pingIntervalSeconds: UInt64 = 10

    /// Mutable flag shared between the receive loop and the ping task.
    /// A single-word Bool; the race window (a ping sent before the
    /// join reply lands) is benign — the server ignores it.
    private final class JoinedFlag: @unchecked Sendable { var value = false }

    /// Split one "<event><json>" frame. Pure function.
    static func splitEvent(_ raw: String) -> (event: Int, payload: JSONValue)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var digits = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber, digits.count < 7 {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard let event = Int(digits), !digits.isEmpty else { return nil }
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "{",
              let data = String(text[index...]).data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return (event, json)
    }

    /// The challenge answer (event 79108): MD5 over
    /// "60#4#5#<unix seconds>#1#1#1#1#<last 8 chars of the
    /// challenge frame>". Pure function.
    static func challengeSign(seconds: Int, challengeSuffix: String) -> String {
        MD5.hex("60#4#5#\(seconds)#1#1#1#1#\(challengeSuffix)")
    }

    /// Decode one event-2584 chat payload into an item. The
    /// content is base64 JSON {m: text, n: name}. Pure function.
    static func chatItem(from payload: JSONValue, roomID: String) -> DanmakuItem? {
        guard let tag = payload["tag"].intValue, tag == 1 || tag == 2,
              let content = payload["content"].stringValue, !content.isEmpty else { return nil }
        var padded = content
        while padded.count % 4 != 0 { padded += "=" }
        guard let decoded = Data(base64Encoded: padded),
              let json = JSONValue.parse(decoded) else { return nil }
        let text = (json["m"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let timestamp: Date
        if let millis = payload["timestamp"].intValue, millis > 0 {
            timestamp = Date(timeIntervalSince1970: TimeInterval(millis > 100_000_000_000 ? millis : millis * 1000) / 1000)
        } else {
            timestamp = Date()
        }
        return DanmakuItem(
            roomID: roomID,
            user: (json["n"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            text: text,
            colorHex: "",
            timestamp: timestamp
        )
    }

    /// A guest device id (Pure Live's _newDeviceId).
    static func newDeviceID() -> String {
        let suffix = (0..<6).map { _ in String(Int.random(in: 0..<10)) }.joined()
        return "web_\(String(Int.random(in: 0..<(1 << 32)), radix: 16))\(suffix)\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    /// Login packet fields (event 512279). Pure function.
    static func loginFields(uid: String, uidToken: String, deviceID: String) -> [String: Any] {
        [
            "uid": uid,
            "cookie": uidToken.replacingOccurrences(of: "###VER2", with: ""),
            "secret": "0",
            "userName": "0",
            "deviceId": deviceID,
            "clientType": "7",
            "netConf": ["clientIp": "0", "countryCode": "CN"] as [String: Any],
        ]
    }

    /// Enter-room packet fields (event 1304). Pure function.
    static func enterRoomFields(roomID: String, deviceID: String) -> [String: Any] {
        [
            "secretKey": "0",
            "seqId": Int(Date().timeIntervalSince1970 * 1000),
            "roomId": roomID,
            "reserver": "1",
            "clientVersion": "0",
            "clientType": "7",
            "version": "15",
            "deviceid": deviceID,
            "other": [] as [Any],
        ]
    }

#if !os(Linux)
    /// Live stream of danmaku for a room (site id, owner id, and
    /// the numeric room id from the studio room).
    static func stream(siteID: String, ownerID: Int, roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let deviceID = newDeviceID()
                guard let account = await requestAccount(deviceID: deviceID) else {
                    continuation.finish()
                    return
                }
                guard let url = URL(string: socketURL) else {
                    continuation.finish()
                    return
                }
                var request = URLRequest(url: url)
                request.setValue("https://www.bigo.tv", forHTTPHeaderField: "Origin")
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()
                var loggedIn = false
                // Shared with the ping task below: a plain `var` captured
                // by an inner Task is a Swift 6 data-race error, so the
                // flag lives in a Sendable box (same pattern as
                // Kilakila JoinBox / SixRoom LoggedInFlag).
                let joinedFlag = JoinedFlag()
                var answeredChallenge = false
                var lastChallengeSuffix = ""
                func send(event: Int, fields: [String: Any]) async {
                    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: []),
                          let text = String(data: data, encoding: .utf8) else { return }
                    try? await socket.send(.string("\(event)\(text)"))
                }
                let ping = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Int(pingIntervalSeconds)))
                        if joinedFlag.value {
                            await send(event: 791, fields: [
                                "status": "0",
                                "seqid": Int(Date().timeIntervalSince1970 * 1000),
                                "flag": "0",
                                "roomId": "0",
                                "ownerStatus": "0",
                                "micUid": "0",
                            ])
                        }
                    }
                }
                defer { ping.cancel() }
                while !Task.isCancelled {
                    do {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let (event, payload) = splitEvent(text) else { continue }
                        switch event {
                        case 79108:
                            // Challenge: answer once, then log in a
                            // second later.
                            guard !answeredChallenge else { continue }
                            answeredChallenge = true
                            lastChallengeSuffix = text.count <= 8 ? text : String(text.suffix(8))
                            let seconds = Int(Date().timeIntervalSince1970)
                            await send(event: 79108, fields: [
                                "appId": "60",
                                "osType": "4",
                                "clientVersion": "5",
                                "timeStamp": seconds,
                                "nonce": "1",
                                "reservedForSecurity": "1",
                                "appSign": "1",
                                "redundancy": "1",
                                "sign": challengeSign(seconds: seconds, challengeSuffix: lastChallengeSuffix),
                            ])
                            try? await Task.sleep(for: .seconds(1))
                            if !loggedIn {
                                await send(event: 512279, fields: loginFields(uid: account.uid, uidToken: account.uidToken, deviceID: deviceID))
                            }
                        case 512535:
                            guard payload["res"].stringValue == "200" else { break }
                            loggedIn = true
                            await send(event: 1304, fields: enterRoomFields(roomID: roomID, deviceID: deviceID))
                        case 1304:
                            guard !joinedFlag.value else { continue }
                            joinedFlag.value = true
                            await send(event: 10776, fields: [
                                "uid": ownerID,
                                "seqId": Int(Date().timeIntervalSince1970 * 1000),
                                "roomid": roomID,
                                "others": [] as [Any],
                            ])
                        case 2584:
                            if let item = chatItem(from: payload, roomID: roomID) {
                                continuation.yield(item)
                            }
                        default:
                            continue
                        }
                    } catch {
                        break
                    }
                }
                socket.cancel(with: .normalClosure, reason: nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Guest account for the chat channel (userId + uidToken).
    private static func requestAccount(deviceID: String) async -> (uid: String, uidToken: String)? {
        guard let url = URL(string: accountURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.bigo.tv", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = "deviceId=\(deviceID)".data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = JSONValue.parse(data),
              let uid = json["data"]["userId"].stringValue, !uid.isEmpty,
              let uidToken = json["data"]["uidToken"].stringValue, !uidToken.isEmpty else {
            return nil
        }
        return (uid, uidToken)
    }
#endif
}
