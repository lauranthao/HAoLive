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
// through it). Fc2Control below is that seat, in Swift:
// Fc2Site opens one per channel, reuses it while it is alive
// (quality switches and lease refreshes read the playlists it
// already announced, no new grant), and closes it when the room
// closes (LiveSite.endPlaybackSession). A control that ends
// (control_disconnection — the grant expired, code 4500 — or a
// dropped socket) never reconnects with a used grant: the owner
// takes a new grant.
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
    /// The owner's picture (member answer only: profile icon /
    /// image). Empty in directory rows — the room then falls back
    /// to the cover (ref Fc2LiveApi.room: avatar, else cover).
    /// A `var` with a default IS a memberwise-init parameter, so
    /// existing construction sites compile unchanged.
    var avatarURL: String = ""
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

    /// Category names (ref Fc2LiveApi.areaName, 3.x's zh.json).
    /// Categories outside the catalog (0 and 8 "unknown", 6
    /// premium, 7 official) have no name.
    static func categoryName(_ category: Int) -> String {
        switch category {
        case 1: return "闲聊"
        case 2, 3: return "游戏 / 作业"
        case 4: return "视频"
        case 5: return "其他"
        case 9: return "音频"
        default: return ""
        }
    }

    /// The English area name 3.x gave directory cards (ref
    /// Fc2LiveApi.legacyAreaName); the keyword search still
    /// matches it, so English searches find the same rooms.
    static func legacyAreaName(_ category: Int) -> String {
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
        // Ref Fc2LiveApi.member: a channel that never existed is
        // answered with status 1 and an empty profile_data.userid.
        if !profile.isNull, profile["userid"].stringValue == nil {
            return nil
        }
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
            // Ref Fc2LiveApi.member: the owner's picture is the
            // profile icon, else the profile image (a field the
            // old code never read — every FC2 avatar was the
            // cover). A bad link is no image, never a failure.
            avatarURL: HaoText.firstNonEmpty(
                image(profile["icon"].stringValue ?? ""),
                image(profile["image"].stringValue ?? "")
            ) ?? "",
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
              let orz = root["orz_raw"].stringValue, orz.count <= 256,
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

    /// The tiers of the reference (ref Fc2LiveApi.tierQualities),
    /// best first. The id is the tier's playlist mode in the
    /// control's HLS answer; the site transcodes every tier, none
    /// is the source.
    static let tierModes = [50, 40, 30, 20, 10]

    /// The display label of a quality id (ref Fc2LiveApi.
    /// tierQualities + autoQuality: 50 is 3 Mbps (β), 40 is 2 Mbps).
    static func qualityLabel(for id: String) -> String {
        switch id {
        case "50": return "超清 3M（β）"
        case "40": return "超清 2M"
        case "30": return "高清"
        case "20": return "标清"
        case "10": return "流畅"
        case "auto": return "自适应 HLS"
        default: return id
        }
    }

    /// The media request headers of a channel (ref Fc2LiveApi.
    /// mediaHeaders, which its HLS relay sent): UA, origin and
    /// the channel page as referer. No cookie — the control
    /// session authorises server-side.
    static func mediaHeaders(channelID: String) -> [String: String] {
        [
            "user-agent": userAgent,
            "origin": origin,
            "referer": channelURL(channelID),
        ]
    }

    /// The playlist families of the control's HLS answer: low
    /// latency (the one the old code read, modes 0, 10, 20, 30,
    /// 90), high latency (mode + 1) and middle latency (mode + 2).
    static let playlistFamilies = ["playlists", "playlists_high_latency", "playlists_middle_latency"]

    /// Pure parser for the get_hls_information _response_ (ref
    /// Fc2LiveApi.hlsPlaylists): every playlist of every family,
    /// by mode. A mode below 10 is a family's master (0 is the
    /// low-latency master the old code played), the others are
    /// single variants (`<tier>` + the family's offset; 90 is
    /// sound only). A row or a family that breaks the rules is
    /// skipped alone; an answer without a usable playlist is an
    /// empty map (the caller fails it), and a non-zero arguments
    /// status is one too — the reference throws StreamUnavailable
    /// there, the caller maps it to a message instead.
    static func parseHlsPlaylists(_ response: JSONValue, expectedChannelID: String) -> [Int: URL] {
        guard response["name"].stringValue == "_response_",
              response["id"].intValue == 1 else { return [:] }
        let arguments = response["arguments"]
        guard arguments["status"].intValue == 0 else { return [:] }
        var found: [Int: URL] = [:]
        for family in playlistFamilies {
            for value in arguments[family].arrayValue {
                guard let mode = value["mode"].intValue, (0...999).contains(mode),
                      value["status"].intValue == 0,
                      let url = playlistURL(value["url"].stringValue, channelID: expectedChannelID, mode: mode) else {
                    continue
                }
                if found[mode] == nil { found[mode] = url }
            }
        }
        return found
    }

    /// One playlist URL, validated (ref Fc2LiveApi._playlist):
    /// https on live.fc2.com or a subdomain, no user info or
    /// fragment, at /a/stream/<channel>/<mode>/master_playlist
    /// (a master, mode < 10) or /playlist (a variant), with
    /// exactly the query parameters `c`, `d` (1–1024 chars) and,
    /// for a master only, `targets` (up to 16 numbers of 1–3
    /// digits).
    static func playlistURL(_ raw: String?, channelID: String, mode: Int) -> URL? {
        guard let raw, !raw.isEmpty, raw.count <= 65536,
              let uri = URL(string: raw),
              uri.scheme == "https",
              uri.user == nil, uri.password == nil,
              isMediaHost(uri.host ?? ""),
              uri.fragment == nil else { return nil }
        let master = mode < 10
        guard uri.path == "/a/stream/\(channelID)/\(mode)/\(master ? "master_playlist" : "playlist")" else { return nil }
        guard let components = URLComponents(url: uri, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }
        let keys = Set(queryItems.map { $0.name })
        let wanted: Set<String> = master ? ["targets", "c", "d"] : ["c", "d"]
        guard keys == wanted else { return nil }
        func token(_ name: String) -> Bool {
            guard let value = queryItems.first(where: { $0.name == name })?.value,
                  !value.isEmpty, value.count <= 1024 else { return false }
            return true
        }
        guard token("c"), token("d") else { return nil }
        if master {
            guard let targets = queryItems.first(where: { $0.name == "targets" })?.value,
                  isTargets(targets) else { return nil }
        }
        return uri
    }

    /// The qualities a channel offers by its HLS answer's
    /// playlists (ref Fc2LiveApi.qualitiesOf), in menu order:
    /// each tier with a variant in any family (so `50` and `40`
    /// only for the channels that have them), then `auto` when a
    /// master is there. Empty when the answer has neither (sound
    /// only).
    static func qualitiesOf(_ playlists: [Int: URL]) -> [String] {
        var ids: [String] = []
        for mode in tierModes {
            if [0, 1, 2].contains(where: { playlists[mode + $0] != nil }) {
                ids.append(String(mode))
            }
        }
        if [0, 1, 2].contains(where: { playlists[$0] != nil }) {
            ids.append("auto")
        }
        return ids
    }

    /// The playlist to play for `quality` among `playlists`
    /// (ref Fc2LiveApi.playlistFor), or nil when there is none:
    /// a tier plays a single variant — its high-latency one
    /// (mode + 1), else its low-latency one, else its
    /// middle-latency one; a tier the channel does not offer falls
    /// back to the next lower tier, then the next higher, then to
    /// a master. `auto` plays the low-latency master, else the
    /// high- or middle-latency master, else the best tier. The
    /// result names the quality that actually plays.
    static func playlistFor(_ playlists: [Int: URL], quality: String) -> (quality: String, url: URL)? {
        func tier(_ mode: Int) -> (String, URL)? {
            for offset in [1, 0, 2] {
                if let url = playlists[mode + offset] { return (String(mode), url) }
            }
            return nil
        }
        func master() -> (String, URL)? {
            for mode in [0, 1, 2] {
                if let url = playlists[mode] { return ("auto", url) }
            }
            return nil
        }
        if quality == "auto" { return master() ?? tierModes.compactMap(tier).first }
        guard let requested = Int(quality), tierModes.contains(requested),
              String(requested) == quality else { return nil }
        let lower = tierModes.filter { $0 < requested }
        let higher = tierModes.reversed().filter { $0 > requested }
        for mode in [requested] + lower + higher {
            if let found = tier(mode) { return found }
        }
        return master()
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
        // Ref Fc2LiveApi.grant: a status other than 0 is
        // StreamUnavailable, not a malformed answer.
        if let status = root["status"].intValue, status != 0 {
            throw LiveSiteError.message("该频道暂时无法播放")
        }
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
/// @unchecked Sendable holder for a WebSocket task, so the
/// task group's @Sendable child tasks may hold it.
private final class Fc2SocketBox: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    init(_ socket: URLSessionWebSocketTask) { self.socket = socket }
}

/// A held FC2 media-control seat (ref Fc2LiveControl,
/// fc2live_control.dart): the WebSocket whose session
/// authorises a channel's HLS playlists. The media server
/// refuses variant playlists once the socket is gone, so
/// whoever opens the control keeps it open for exactly as long
/// as its consumer reads the playlist, and closes it
/// afterwards. The socket pings every 15 s; anything else, a
/// `control_disconnection` (the grant expired, code 4500), an
/// error or the socket closing ends the control, which never
/// reconnects with a used grant — the owner takes a new grant.
final class Fc2Control: @unchecked Sendable {
    let channelID: String
    /// Every playlist the HLS answer named, by mode.
    let playlists: [Int: URL]
    private let socket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var _closed = false
    private var _ended = false
    private var _tasks: [Task<Void, Never>] = []

    /// Whether the control has ended: its playlist must not be
    /// opened any more.
    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !_closed && !_ended
    }

    private init(channelID: String, playlists: [Int: URL], socket: URLSessionWebSocketTask) {
        self.channelID = channelID
        self.playlists = playlists
        self.socket = socket
    }

    /// Open a control seat for a fresh grant and wait for the HLS
    /// answer (ref Fc2LiveControl.open: 20 s startup timeout).
    /// The caller owns the control and closes it when its
    /// consumer is done.
    static func open(grant: Fc2ControlGrant) async throws -> Fc2Control {
        var components = URLComponents(url: grant.webSocket, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "control_token", value: grant.controlToken)]
        guard let url = components?.url else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(Fc2ControlSession.origin, forHTTPHeaderField: "Origin")
        request.setValue(Fc2ControlSession.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("l_ortkn=\(grant.orz)", forHTTPHeaderField: "Cookie")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        let box = Fc2SocketBox(socket)
        let playlists: [Int: URL]
        do {
            playlists = try await withThrowingTaskGroup(of: [Int: URL].self) { group in
                group.addTask {
                    let socket = box.socket
                    var requested = false
                    while true {
                        let message = try await socket.receive()
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
                            // A non-zero answer status is a refused
                            // channel, not a malformed answer.
                            if let status = json["arguments"]["status"].intValue, status != 0 {
                                throw LiveSiteError.message("该频道暂时无法播放")
                            }
                            let found = Fc2ControlSession.parseHlsPlaylists(json, expectedChannelID: grant.channelID)
                            guard !found.isEmpty else { throw LiveSiteError.invalidResponse }
                            return found
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
                guard let found = try await group.next() else {
                    throw LiveSiteError.invalidResponse
                }
                group.cancelAll()
                return found
            }
        } catch {
            socket.cancel(with: .normalClosure, reason: nil)
            throw error
        }
        let control = Fc2Control(channelID: grant.channelID, playlists: playlists, socket: socket)
        control.startBackgroundLoops()
        return control
    }

    /// Receive loop (a later `control_disconnection` or a dropped
    /// socket ends the control) + the 15 s WebSocket ping (ref
    /// Fc2LiveControl.pingInterval).
    private func startBackgroundLoops() {
        let receive = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.socket.receive()
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let json = JSONValue.parse(data),
                       json["name"].stringValue == "control_disconnection" {
                        self.markEnded()
                        return
                    }
                } catch {
                    self.markEnded()
                    return
                }
            }
        }
        let ping = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self.isAlive else { break }
                self.socket.sendPing { _ in }
            }
        }
        lock.lock()
        _tasks = [receive, ping]
        lock.unlock()
    }

    /// Ends the control: the timers stop and the socket is closed
    /// (ref Fc2LiveControl.close). Idempotent.
    func close() {
        let tasks: [Task<Void, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            if _closed { return [] }
            _closed = true
            return _tasks
        }()
        for task in tasks { task.cancel() }
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func markEnded() {
        lock.lock()
        let already = _closed || _ended
        _ended = true
        lock.unlock()
        guard !already else { return }
        socket.cancel(with: .normalClosure, reason: nil)
    }
}
#endif
}
