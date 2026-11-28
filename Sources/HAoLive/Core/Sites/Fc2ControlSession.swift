// Fc2ControlSession.swift
// HAo Live — FC2 Live control session: member lookup, control
// grant, and the WebSocket that hands over the HLS master.
// Pure Live's fc2_api.dart / fc2_control_session.dart,
// re-implemented from scratch for HAo Live.
//
// FC2 has NO direct stream URL. Playback needs a control seat:
//   POST /api/memberApi.php (channel=1&profile=1&user=1&
//     streamid=<id>) -> room + channel version
//   POST /api/getControlServer.php (channel_id, mode=play,
//     orz=, channel_version, client_version "2.1.0\n [1]",
//     client_type=pc, client_app=browser_hls, ipv6=)
//     -> {status 0, url (wss://…/control/channels/<id>),
//     control_token, orz_raw}
//   WSS <url>?control_token=<token>, Cookie l_ortkn=<orz_raw>
//     -> connect_complete -> send {"name":
//     "get_hls_information","arguments":{},"id":1} ->
//     _response_ id 1 {status 0, playlists[] {mode 0, status 0,
//     url https://…/a/stream/<id>/0/master_playlist
//     ?targets=…&c=…&d=…}} — that URL is the playable master.
//     The signed query (targets/c/d) is used verbatim.
// Verified live from this VM 2026-11-28: list 65 channels
// (51 public), memberApi for 1024233 (version kun-…, publish 1),
// getControlServer (status 0, wss us-west-1-media-worker1068),
// WS handshake 101 -> initial_connect -> connect_complete ->
// _response_ with the master_playlist URL (mode 0) plus the
// per-mode playlists. Comment frames arrived on the same
// channel (see Fc2Danmaku.swift).
//
// The control WebSocket is a live seat: Pure Live keeps it open
// for the whole playback (the platform keeps HLS grants alive
// through it). HAoLive's playURLs is one-shot — this helper
// opens the seat, reads the master, and closes it. The master
// URL + cookie keep working while the grant is valid, but
// playback may stop when the grant expires and the player cannot
// renew it. Same follow-up as niconico, not faked here.
//
// No login: pay/ticket/login rooms (directory) and limited/fee/
// ticket/login_only rooms (member) are restricted and never
// played. The orz/control_token are per-session server grants,
// not copied keys.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One FC2 room, directory or member shape unified.
struct Fc2Room {
    enum State {
        case live, offline, restricted
    }

    let channelID: String
    let userName: String
    let title: String
    let description: String
    let coverURL: String
    let categoryID: Int
    let categoryName: String
    let currentViewers: Int?
    let totalViewers: Int?
    let state: State
    let isAdult: Bool
    /// Restriction that makes the room unplayable; nil when public.
    let restriction: String?
}

/// One control grant (per-session server material).
struct Fc2ControlGrant {
    let channelID: String
    let webSocket: URL
    let controlToken: String
    let orz: String
}

enum Fc2ControlSession {
    static let origin = "https://live.fc2.com"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    static let headers: [String: String] = [
        "User-Agent": userAgent,
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
        "Origin": origin,
        "Referer": "\(origin)/",
        "X-Requested-With": "XMLHttpRequest",
    ]

    /// Channel id validity: 1-12 digits, no leading zero
    /// (Pure Live's Fc2Link._channelId).
    static func parseChannelID(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.range(of: #"^[1-9][0-9]{0,11}$"#, options: .regularExpression) != nil {
            return input
        }
        guard let url = URL(string: input),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "live.fc2.com",
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        let locales = ["en", "es", "de", "fr", "id", "ja", "ko", "pt", "ru", "th", "tw", "vi", "zh"]
        if segments.count == 1,
           segments[0].range(of: #"^[1-9][0-9]{0,11}$"#, options: .regularExpression) != nil {
            return segments[0]
        }
        if segments.count == 2, locales.contains(segments[0].lowercased()),
           segments[1].range(of: #"^[1-9][0-9]{0,11}$"#, options: .regularExpression) != nil {
            return segments[1]
        }
        return nil
    }

    static func channelURL(_ channelID: String) -> String {
        "\(origin)/\(channelID)/"
    }

    /// Category names (Pure Live's Fc2Api.categoryName).
    static func categoryName(_ category: Int) -> String {
        switch category {
        case 1: return "Idle Chat"
        case 2, 3: return "Game / Work"
        case 4: return "Video"
        case 5: return "Other"
        case 9: return "Audio"
        default: return "FC2 Live"
        }
    }

    // MARK: - Directory

    /// Restriction from the directory's pay/ticket/login flags.
    /// Returns a non-nil marker when the room is gated.
    static func directoryRestriction(pay: Int, ticket: Int, login: Int) -> String? {
        if pay != 0 || ticket != 0 { return "paid" }
        if login != 0 { return "login" }
        return nil
    }

    /// Pure parser for allchannellist.php. Only type == 1
    /// (public media rooms) are kept. Testable without the network.
    static func parseDirectory(_ root: JSONValue) -> [Fc2Room] {
        guard (root["time"].intValue ?? 0) >= 1 else { return [] }
        var seen = Set<String>()
        var rooms: [Fc2Room] = []
        for value in root["channel"].arrayValue {
            guard value["type"].intValue == 1,
                  let room = directoryRoom(value),
                  seen.insert(room.channelID).inserted else { continue }
            rooms.append(room)
        }
        return rooms
    }

    static func directoryRoom(_ data: JSONValue) -> Fc2Room? {
        guard let id = parseChannelID(data["id"].stringValue ?? "") else { return nil }
        let restriction = directoryRestriction(
            pay: data["pay"].intValue ?? 0,
            ticket: data["tid"].intValue ?? 0,
            login: data["login"].intValue ?? 0
        )
        let categoryID = data["category"].intValue ?? 0
        guard (0...99).contains(categoryID) else { return nil }
        return Fc2Room(
            channelID: id,
            userName: firstText([data["name"].stringValue, id]),
            title: firstText([data["title"].stringValue, data["name"].stringValue, id]),
            description: "",
            coverURL: image(data["image"].stringValue ?? ""),
            categoryID: categoryID,
            categoryName: categoryName(categoryID),
            currentViewers: nonNegative(data["count"].intValue),
            totalViewers: nonNegative(data["total"].intValue),
            state: restriction == nil ? .live : .restricted,
            isAdult: false,
            restriction: restriction
        )
    }

    // MARK: - Member

    /// Restriction from the member flags. "limited" is
    /// unplayable for any reason; fee/ticket is paid; login_only
    /// needs a login.
    static func memberRestriction(limited: Int, fee: Int, ticketID: Int, ticketOnly: Int, loginOnly: Int) -> String? {
        if limited != 0 { return "limited" }
        if fee != 0 || ticketID != 0 || ticketOnly != 0 { return "paid" }
        if loginOnly != 0 { return "login" }
        return nil
    }

    /// Pure parser for memberApi.php. Returns the room and the
    /// channel version the control call needs. Testable without
    /// the network.
    static func parseMember(_ root: JSONValue, expectedChannelID: String) -> (room: Fc2Room, version: String)? {
        guard root["status"].intValue == 1 else { return nil }
        let data = root["data"]
        let channel = data["channel_data"]
        let profile = data["profile_data"]
        guard let id = parseChannelID(channel["channelid"].stringValue ?? ""),
              id == expectedChannelID else { return nil }
        let published = channel["is_publish"].intValue == 1
        let restriction = memberRestriction(
            limited: channel["is_limited"].intValue ?? 0,
            fee: channel["fee"].intValue ?? 0,
            ticketID: channel["ticketid"].intValue ?? 0,
            ticketOnly: channel["ticket_only"].intValue ?? 0,
            loginOnly: channel["login_only"].intValue ?? 0
        )
        let categoryID = channel["category"].intValue ?? 0
        guard (0...99).contains(categoryID) else { return nil }
        let version = channel["version"].stringValue ?? ""
        guard !version.isEmpty, version.count <= 256 else { return nil }
        let state: Fc2Room.State
        if !published {
            state = .offline
        } else if restriction != nil {
            state = .restricted
        } else {
            state = .live
        }
        let room = Fc2Room(
            channelID: id,
            userName: firstText([profile["name"].stringValue, channel["tname"].stringValue, id]),
            title: firstText([channel["title"].stringValue, profile["name"].stringValue, id]),
            description: (channel["info"].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            coverURL: image(channel["image"].stringValue ?? ""),
            categoryID: categoryID,
            categoryName: firstText([channel["category_name"].stringValue, categoryName(categoryID)]),
            currentViewers: nonNegative(channel["count"].intValue),
            totalViewers: nonNegative(channel["total"].intValue),
            state: state,
            isAdult: channel["adult"].intValue == 1,
            restriction: restriction
        )
        return (room, version)
    }

    // MARK: - Control grant

    /// Pure parser for getControlServer.php. Testable without the
    /// network.
    static func parseControlGrant(_ root: JSONValue, expectedChannelID: String) -> Fc2ControlGrant? {
        guard root["status"].intValue == 0,
              let rawURL = root["url"].stringValue, rawURL.count <= 2048,
              let token = root["control_token"].stringValue, !token.isEmpty, token.count <= 4096,
              let orz = root["orz_raw"].stringValue,
              orz.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil,
              let uri = URL(string: rawURL),
              uri.scheme == "wss",
              uri.user == nil, uri.password == nil,
              isFc2Host(uri.host ?? ""),
              uri.path == "/control/channels/\(expectedChannelID)",
              uri.query == nil, uri.fragment == nil else { return nil }
        return Fc2ControlGrant(channelID: expectedChannelID, webSocket: uri, controlToken: token, orz: orz)
    }

    static func isFc2Host(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "live.fc2.com" || value.hasSuffix(".live.fc2.com")
    }

    /// Pure parser for the get_hls_information _response_:
    /// the mode-0, status-0 playlist URL. Testable without the
    /// network.
    static func parseHlsResponse(_ response: JSONValue, expectedChannelID: String) -> URL? {
        guard response["name"].stringValue == "_response_",
              response["id"].intValue == 1 else { return nil }
        let arguments = response["arguments"]
        guard arguments["status"].intValue == 0 else { return nil }
        for value in arguments["playlists"].arrayValue {
            guard value["mode"].intValue == 0, value["status"].intValue == 0,
                  let rawURL = value["url"].stringValue,
                  let uri = URL(string: rawURL),
                  uri.scheme == "https",
                  uri.user == nil, uri.password == nil,
                  isMediaHost(uri.host ?? ""),
                  uri.path == "/a/stream/\(expectedChannelID)/0/master_playlist",
                  uri.fragment == nil,
                  let components = URLComponents(url: uri, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems,
                  !queryItems.isEmpty,
                  queryItems.allSatisfy({ ["targets", "c", "d"].contains($0.name) }),
                  queryItems.contains(where: { $0.name == "c" && !($0.value ?? "").isEmpty }),
                  queryItems.contains(where: { $0.name == "d" && !($0.value ?? "").isEmpty }),
                  queryItems.contains(where: { $0.name == "targets" && isTargets($0.value ?? "") }) else {
                continue
            }
            return uri
        }
        return nil
    }

    static func isMediaHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "live.fc2.com" || value.hasSuffix(".live.fc2.com")
    }

    static func isTargets(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.range(of: #"^\d{1,3}(?:,\d{1,3}){0,15}$"#, options: .regularExpression) != nil
    }

    // MARK: - Network

    private static func post(_ path: String, form: [String: String], http: HTTPClient) async throws -> JSONValue {
        let data = try await http.postForm("\(origin)\(path)", fields: form, headers: headers)
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        return json
    }

    /// memberApi for one channel.
    static func member(channelID: String, http: HTTPClient) async throws -> (room: Fc2Room, version: String) {
        guard let channelID = parseChannelID(channelID) else {
            throw LiveSiteError.roomNotFound(channelID)
        }
        let root = try await post("/api/memberApi.php", form: ["channel": "1", "profile": "1", "user": "1", "streamid": channelID], http: http)
        guard let parsed = parseMember(root, expectedChannelID: channelID) else {
            throw LiveSiteError.roomNotFound(channelID)
        }
        return parsed
    }

    /// The control grant for a live, public channel. Throws when
    /// the room is offline or restricted — there is no grant for
    /// those.
    static func controlGrant(channelID: String, http: HTTPClient) async throws -> Fc2ControlGrant {
        let (room, version) = try await member(channelID: channelID, http: http)
        switch room.state {
        case .offline: throw LiveSiteError.message("该房间未开播")
        case .restricted: throw LiveSiteError.message("该房间受限，无法观看")
        case .live: break
        }
        let root = try await post("/api/getControlServer.php", form: [
            "channel_id": channelID,
            "mode": "play",
            "orz": "",
            "channel_version": version,
            "client_version": "2.1.0\n [1]",
            "client_type": "pc",
            "client_app": "browser_hls",
            "ipv6": "",
        ], http: http)
        guard let grant = parseControlGrant(root, expectedChannelID: channelID) else {
            throw LiveSiteError.invalidResponse
        }
        return grant
    }

    // MARK: - Helpers

    static func firstText(_ values: [String?]) -> String {
        for value in values {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    static func nonNegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    /// An https image on an fc2.com host, or "" when unusable.
    static func image(_ raw: String) -> String {
        guard !raw.isEmpty,
              let uri = URL(string: raw),
              uri.scheme == "https",
              uri.user == nil, uri.password == nil, uri.fragment == nil,
              let host = uri.host?.lowercased(),
              host == "fc2.com" || host.hasSuffix(".fc2.com") else { return "" }
        return uri.absoluteString
    }

#if !os(Linux)
    /// Open a control seat, read the HLS master URL, and close
    /// the seat again (see the lifetime caveat in the file
    /// header). Returns the master URL plus the Cookie header
    /// the player must send with it.
    static func fetchMaster(channelID: String, http: HTTPClient) async throws -> (masterURL: URL, cookie: String) {
        let grant = try await controlGrant(channelID: channelID, http: http)
        var components = URLComponents(url: grant.webSocket, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "control_token", value: grant.controlToken)]
        guard let url = components?.url else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("l_ortkn=\(grant.orz)", forHTTPHeaderField: "Cookie")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let box = Fc2SocketBox(socket)
        let master = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                let socket = box.socket
                var requested = false
                while true {
                    let message: URLSessionWebSocketTask.Message = try await socket.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let json = JSONValue.parse(data) else { continue }
                    switch json["name"].stringValue {
                    case "connect_complete":
                        if !requested {
                            requested = true
                            try await socket.send(.string("{\"name\":\"get_hls_information\",\"arguments\":{},\"id\":1}"))
                        }
                    case "_response_":
                        if let master = parseHlsResponse(json, expectedChannelID: grant.channelID) {
                            return master
                        }
                        throw LiveSiteError.invalidResponse
                    case "control_disconnection":
                        throw LiveSiteError.networkUnavailable
                    default:
                        continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw LiveSiteError.networkUnavailable
            }
            guard let master = try await group.next() else {
                throw LiveSiteError.invalidResponse
            }
            group.cancelAll()
            return master
        }
        return (master, "l_ortkn=\(grant.orz)")
    }

    /// @unchecked Sendable holder for a WebSocket task (see
    /// NiconicoMaster.SocketBox for the same pattern).
    final class Fc2SocketBox: @unchecked Sendable {
        let socket: URLSessionWebSocketTask
        init(_ socket: URLSessionWebSocketTask) { self.socket = socket }
    }
#endif
}
