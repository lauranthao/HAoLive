// NiconicoMaster.swift
// HAo Live — niconico watch session + HLS master reader.
// Pure Live's niconico_watch.dart / niconico_session.dart /
// niconico_stream.dart / niconico_quality_catalog.dart,
// re-implemented from scratch for HAo Live.
//
// niconico has NO direct stream URL. Playback needs a watch
// session: GET the watch page (embedded JSON), open the relive
// WebSocket, send startWatching + getAkashic, wait for the "seat"
// and "stream" messages. The stream grant is a master m3u8 URI on
// livedelivery.dlive.nicovideo.jp plus path-scoped session cookies
// (CloudFront signed cookies + a session cookie); the master is
// fetched with those cookies and its variants are the qualities.
// Verified live from this VM 2026-11-28: watch page lv351902860
// (ON_AIR, needLogin false, canWatch true, frontendId 9), WS
// handshake answered serverTime -> seat (keepIntervalSec 30) ->
// stream (uri …/multivariant/variant.m3u8, qualities abr /
// super_high / 1.5Mbps480p30fps / 480kbps288p30fps / audio_high /
// audio_only, 13 cookies), master fetched with cookies -> HTTP 200,
// 3 video variants (1280x720 @3Mbps, 854x480 @1.5Mbps,
// 512x288 @480Kbps).
//
// Lifetime caveat (honest): the seat is a live session — Pure Live
// holds it open for the whole playback and sends keepSeat every
// keepIntervalSec. HAoLive's playURLs is one-shot: this helper
// opens the session, reads the master, and closes it. The variant
// URLs + cookies keep working while the grant is valid, but
// playback may stop when the seat/cookies expire and the player
// cannot renew them. A player-layer session (keep the seat alive
// for the whole playback) is the follow-up; it is NOT faked here.
//
// No login: access == loginRequired (needLogin) or regionRestricted
// (country restriction) rooms are reported as such and never
// played. The watch WebSocket URL carries an audience_token issued
// for this anonymous session — it is per-session server material,
// not a copied key.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One niconico program's watch-page snapshot.
struct NiconicoWatch {
    enum Status: String {
        case scheduled, onAir, ended
    }

    enum Access {
        case allowed, loginRequired, regionRestricted, denied
    }

    let programID: String
    let title: String
    let broadcaster: String
    let status: Status
    let access: Access
    /// Cumulative watch count (not concurrent viewers).
    let watchCount: Int?
    /// The relive WebSocket URL from the page (wss://a.live2…),
    /// without frontend_id (added when connecting).
    let webSocketURL: URL?
    let frontendID: Int?
    let coverURL: String?
    let avatarURL: String?

    static func isProgramID(_ value: String) -> Bool {
        value.range(of: #"^lv[1-9][0-9]{0,17}$"#, options: .regularExpression) != nil
    }

    static func isBroadcasterRoomID(_ value: String) -> Bool {
        value.range(of: #"^(?:user/[1-9][0-9]{0,17}|ch[1-9][0-9]{0,17})$"#, options: .regularExpression) != nil
    }

    /// Parse a program id out of a bare id, a watch URL, or a
    /// watch page URL with query/fragment. Returns nil for anything
    /// else (never guesses).
    static func parseInput(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 2048 else { return nil }
        if value.hasPrefix("lv") { return isProgramID(value) ? value : nil }
        guard let match = value.range(of: #"^https://live\.nicovideo\.jp/watch/(lv[1-9][0-9]{0,17})(?:\?[^#\s]*)?(?:#[^\s]*)?$"#, options: .regularExpression),
              let idRange = value.range(of: #"lv[1-9][0-9]{0,17}"#, options: .regularExpression, range: match) else {
            return nil
        }
        let id = String(value[idRange])
        return isProgramID(id) ? id : nil
    }

    /// Parse the watch page HTML: the single
    /// <script id="embedded-data" data-props="…"> node carries the
    /// page JSON, HTML-escaped once. Pure function, testable
    /// without the network.
    static func parsePage(_ html: String, programID: String) -> NiconicoWatch? {
        guard isProgramID(programID),
              let scriptRange = html.range(of: "embedded-data") else { return nil }
        let tail = html[scriptRange.upperBound...]
        guard let propsRange = tail.range(of: "data-props=\"") else { return nil }
        let valueStart = propsRange.upperBound
        guard let valueEnd = tail[valueStart...].firstIndex(of: "\"") else { return nil }
        let escaped = String(tail[valueStart..<valueEnd])
        let unescaped = Self.htmlUnescape(escaped)
        guard let data = unescaped.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return parseData(json, programID: programID)
    }

    /// Parse the embedded-data JSON object. Pure function.
    static func parseData(_ data: JSONValue, programID: String) -> NiconicoWatch? {
        guard isProgramID(programID) else { return nil }
        let program = data["program"]
        guard program["nicoliveProgramId"].stringValue == programID else { return nil }
        let status: Status
        switch program["status"].stringValue {
        case "RELEASED": status = .scheduled
        case "ON_AIR": status = .onAir
        case "ENDED": status = .ended
        default: return nil
        }
        let needsLogin = data["programWatch"]["condition"]["needLogin"].boolValue ?? false
        let userWatch = data["userProgramWatch"]
        let countryRestricted = userWatch["isCountryRestrictionTarget"].boolValue ?? false
        let canWatch = userWatch["canWatch"].boolValue ?? false
        let access: Access
        if countryRestricted {
            access = .regionRestricted
        } else if needsLogin {
            access = .loginRequired
        } else if canWatch {
            access = .allowed
        } else {
            access = .denied
        }
        var socket: URL?
        var frontendID: Int?
        if status == .onAir && access == .allowed {
            let site = data["site"]
            if let raw = site["relive"]["webSocketUrl"].stringValue,
               let frontend = site["frontendId"].intValue, frontend > 0, frontend <= 9999,
               let uri = URL(string: raw),
               uri.scheme == "wss", uri.host == "a.live2.nicovideo.jp",
               uri.path.range(of: #"^/(?:unama/)?wsapi/v2/watch/[1-9][0-9]*$"#, options: .regularExpression) != nil {
                socket = uri
                frontendID = frontend
            }
        }
        let count = program["statistics"]["watchCount"].intValue
        let supplier = program["supplier"]
        return NiconicoWatch(
            programID: programID,
            title: program["title"].stringValue ?? "",
            broadcaster: supplier["name"].stringValue ?? "",
            status: status,
            access: access,
            watchCount: count,
            webSocketURL: socket,
            frontendID: frontendID,
            coverURL: Self.coverURL(program),
            avatarURL: Self.publicImage(supplier["icons"]["uri150x150"].stringValue)
        )
    }

    /// Screenshot / thumbnail artwork, presentation-only: a
    /// malformed link is dropped, never fatal.
    private static func coverURL(_ program: JSONValue) -> String? {
        let screenshot = program["screenshot"]["urlSet"]
        return publicImage(screenshot["middle"].stringValue)
            ?? publicImage(screenshot["large"].stringValue)
            ?? publicImage(screenshot["small"].stringValue)
            ?? publicImage(program["thumbnail"]["huge"]["s640x360"].stringValue)
            ?? publicImage(program["thumbnail"]["large"].stringValue)
            ?? publicImage(program["thumbnail"]["small"].stringValue)
    }

    /// Only https artwork on niconico's own image hosts.
    static func publicImage(_ value: String?) -> String? {
        guard let value, value.count <= 8192,
              let uri = URL(string: value), uri.scheme == "https",
              let host = uri.host,
              host.hasSuffix(".nimg.jp") || host.hasSuffix(".nicovideo.jp") else { return nil }
        return value
    }

    /// Unescape one level of HTML entities in an attribute value
    /// (&quot; &amp; &lt; &gt; &#39; &#x..; &#..;).
    static func htmlUnescape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        var index = string.startIndex
        while index < string.endIndex {
            if string[index] == "&" {
                if let semi = string[index...].firstIndex(of: ";"),
                   semi < string.index(index, offsetBy: 10, limitedBy: string.endIndex) ?? string.endIndex {
                    let entity = String(string[string.index(after: index)..<semi])
                    switch entity {
                    case "quot": out.append("\"")
                    case "amp": out.append("&")
                    case "lt": out.append("<")
                    case "gt": out.append(">")
                    case "apos", "#39": out.append("'")
                    default:
                        if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
                           let code = UInt32(entity.dropFirst(2), radix: 16),
                           let scalar = Unicode.Scalar(code) {
                            out.append(Character(scalar))
                        } else if entity.hasPrefix("#"),
                                  let code = UInt32(entity.dropFirst()),
                                  let scalar = Unicode.Scalar(code) {
                            out.append(Character(scalar))
                        } else {
                            out.append("&")
                            out.append(entity)
                            out.append(";")
                        }
                    }
                    index = string.index(after: semi)
                    continue
                }
            }
            out.append(string[index])
            index = string.index(after: index)
        }
        return out
    }
}

/// One HLS variant from a niconico master playlist.
struct NiconicoVariant {
    let url: URL
    let resolution: String
    let bandwidth: Int

    var label: String {
        let parts = resolution.split(separator: "x")
        if parts.count == 2, let height = parts.last {
            return "\(height)p"
        }
        return resolution
    }
}

enum NiconicoMaster {
    static let origin = "https://live.nicovideo.jp"

    /// Fetch a watch page and parse it. The caller passes the
    /// program id (lv…) or a broadcaster room id (user/… / ch…);
    /// a broadcaster id is resolved through the page's canonical
    /// link first.
    static func fetchWatch(programOrRoomID: String, http: HTTPClient) async throws -> NiconicoWatch {
        let headers = ["User-Agent": "Mozilla/5.0", "Referer": "\(origin)/"]
        if NiconicoWatch.isProgramID(programOrRoomID) {
            let data = try await http.get("\(origin)/watch/\(programOrRoomID)", headers: headers)
            guard let html = String(data: data, encoding: .utf8),
                  let watch = NiconicoWatch.parsePage(html, programID: programOrRoomID) else {
                throw LiveSiteError.roomNotFound(programOrRoomID)
            }
            return watch
        }
        guard NiconicoWatch.isBroadcasterRoomID(programOrRoomID) else {
            throw LiveSiteError.roomNotFound(programOrRoomID)
        }
        let data = try await http.get("\(origin)/watch/\(programOrRoomID)", headers: headers)
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.roomNotFound(programOrRoomID)
        }
        guard let programID = Self.canonicalProgramID(in: html) else {
            throw LiveSiteError.roomNotFound(programOrRoomID)
        }
        guard let watch = NiconicoWatch.parsePage(html, programID: programID) else {
            throw LiveSiteError.roomNotFound(programOrRoomID)
        }
        return watch
    }

    /// The canonical /watch/lv… link in a broadcaster page.
    static func canonicalProgramID(in html: String) -> String? {
        guard let range = html.range(of: "canonical", options: .caseInsensitive) else { return nil }
        let tail = String(html[range.upperBound...])
        guard let match = tail.range(of: #"/watch/(lv[1-9][0-9]{0,17})"#, options: .regularExpression) else { return nil }
        let id = String(tail[match]).dropFirst("/watch/".count).dropLast()
        let programID = String(id)
        return NiconicoWatch.isProgramID(programID) ? programID : nil
    }

    /// Parse a master playlist into variants (RESOLUTION +
    /// BANDWIDTH required, duplicates rejected). Pure function,
    /// testable without the network.
    static func parseVariants(_ text: String, baseURL: URL) -> [NiconicoVariant] {
        var variants: [NiconicoVariant] = []
        var seen = Set<String>()
        var pending: [String: String]?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = TwitchSite.parsePlaylistAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let attributes = pending else { continue }
            pending = nil
            guard let resolution = attributes["RESOLUTION"],
                  let bandwidthText = attributes["BANDWIDTH"],
                  let bandwidth = Int(bandwidthText),
                  let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            let key = "\(resolution)@\(bandwidth)"
            guard seen.insert(key).inserted else { continue }
            variants.append(NiconicoVariant(url: url, resolution: resolution, bandwidth: bandwidth))
        }
        variants.sort {
            let ha = Int($0.resolution.split(separator: "x").last ?? "0") ?? 0
            let hb = Int($1.resolution.split(separator: "x").last ?? "0") ?? 0
            if ha != hb { return ha > hb }
            return $0.bandwidth > $1.bandwidth
        }
        return variants
    }

    /// Validate one stream-grant cookie row (name/value/path/
    /// domain/secure, as issued by the session). Returns the
    /// "name=value" pair, or nil when the row is unusable.
    static func cookiePair(_ entry: JSONValue) -> String? {
        guard let name = entry["name"].stringValue,
              name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
              !name.hasPrefix("__Host-"),
              let value = entry["value"].stringValue,
              !value.contains(";"), !value.contains("\""), !value.contains("\\"),
              let path = entry["path"].stringValue,
              path.range(of: #"^/hls/[A-Za-z0-9_/-]+$"#, options: .regularExpression) != nil,
              let domain = entry["domain"].stringValue,
              domain == "nicovideo.jp" || domain == ".nicovideo.jp",
              entry["secure"].boolValue == true else { return nil }
        return "\(name)=\(value)"
    }

#if !os(Linux)
    /// Open a watch session for an allowed, on-air program, read
    /// its master playlist, and close the session again (see the
    /// lifetime caveat in the file header). Returns the variants
    /// plus the Cookie header the player must send with them.
    static func fetchVariants(watch: NiconicoWatch, http: HTTPClient) async throws -> (variants: [NiconicoVariant], cookieHeader: String) {
        guard watch.status == .onAir else { return ([], "") }
        guard watch.access == .allowed else {
            switch watch.access {
            case .loginRequired: throw LiveSiteError.message("该节目需要登录后才能观看")
            case .regionRestricted: throw LiveSiteError.message("该节目在当前地区无法观看")
            default: throw LiveSiteError.message("该节目暂时无法观看")
            }
        }
        guard let socketURL = watch.webSocketURL,
              let frontendID = watch.frontendID else { throw LiveSiteError.invalidResponse }
        var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "frontend_id", value: String(frontendID)))
        components?.queryItems = items
        guard let url = components?.url else { throw LiveSiteError.invalidResponse }
        let grant = try await openSession(url: url)
        let cookieHeader = grant.cookies.joined(separator: "; ")
        let data = try await http.get(
            grant.masterURL.absoluteString,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Origin": origin,
                "Referer": "\(origin)/watch/\(watch.programID)",
                "Cookie": cookieHeader,
            ]
        )
        guard let text = String(data: data, encoding: .utf8) else { throw LiveSiteError.invalidResponse }
        return (parseVariants(text, baseURL: grant.masterURL), cookieHeader)
    }

    /// One watch-session grant: the master URI plus its cookies.
    struct Grant {
        let masterURL: URL
        let cookies: [String]
    }

    /// Open the relive WebSocket, send startWatching + getAkashic,
    /// and wait for the seat + stream messages (25s deadline).
    /// Answers ping with pong. Closes the socket before returning.
    /// The socket rides in an @unchecked Sendable box so the task
    /// group's @Sendable child tasks may hold it (same pattern as
    /// the codebase's other @unchecked Sendable holders).
    static func openSession(url: URL) async throws -> Grant {
        var request = URLRequest(url: url)
        request.setValue("https://live.nicovideo.jp", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let box = SocketBox(socket)
        let startWatching = """
            {"type":"startWatching","data":{"stream":{"quality":"abr","protocol":"hls","latency":"high","chasePlay":false},"room":{"protocol":"webSocket","commentable":false},"reconnect":false}}
            """
        let getAkashic = """
            {"type":"getAkashic","data":{"chasePlay":false}}
            """
        try await socket.send(.string(startWatching))
        try await socket.send(.string(getAkashic))
        return try await withThrowingTaskGroup(of: Grant.self) { group in
            group.addTask {
                let socket = box.socket
                var hasSeat = false
                while true {
                    let message: URLSessionWebSocketTask.Message = try await socket.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let json = JSONValue.parse(data) else { continue }
                    switch json["type"].stringValue {
                    case "ping":
                        try? await socket.send(.string("{\"type\":\"pong\"}"))
                    case "seat":
                        hasSeat = true
                    case "stream":
                        guard hasSeat else { continue }
                        return try Self.grant(fromStream: json["data"])
                    case "error", "disconnect":
                        throw LiveSiteError.invalidResponse
                    default:
                        continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw LiveSiteError.networkUnavailable
            }
            guard let grant = try await group.next() else {
                throw LiveSiteError.invalidResponse
            }
            group.cancelAll()
            return grant
        }
    }

    /// @unchecked Sendable holder for a WebSocket task (see
    /// openSession).
    final class SocketBox: @unchecked Sendable {
        let socket: URLSessionWebSocketTask
        init(_ socket: URLSessionWebSocketTask) { self.socket = socket }
    }

    /// Validate a "stream" message into a grant: https master URI
    /// on livedelivery.dlive.nicovideo.jp + its cookies.
    static func grant(fromStream data: JSONValue) throws -> Grant {
        guard data["protocol"].stringValue == "hls",
              let rawURI = data["uri"].stringValue,
              let uri = URL(string: rawURI),
              uri.scheme == "https",
              uri.host == "livedelivery.dlive.nicovideo.jp",
              uri.path.hasPrefix("/hls/playlists/"),
              uri.path.hasSuffix(".m3u8") else {
            throw LiveSiteError.invalidResponse
        }
        let cookies = data["cookies"].arrayValue.compactMap { cookiePair($0) }
        return Grant(masterURL: uri, cookies: cookies)
    }
#endif
}
