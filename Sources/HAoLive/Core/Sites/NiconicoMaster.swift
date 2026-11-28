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
// Lifetime (ref NiconicoSeat, niconico_seat.dart): the seat is a
// live session — the owner holds it open for the whole playback
// and sends keepSeat every keepIntervalSec (and on ping, with
// pong); a later `stream` message replaces the grant and revokes
// the old one; error / disconnect / 90 s of silence ends it.
// NiconicoSession below is that seat, in Swift: NiconicoSite
// opens one per program, reuses it while it is alive (quality
// switches and lease refreshes re-read the master through it),
// and closes it when the room closes (LiveSite.endPlaybackSession).
// The grant's cookies are path-scoped (ref NiconicoGrant.
// cookieHeaderFor): every request carries only the cookies of
// its own path — all of them in one header is refused with 403 —
// and already-expired cookies are dropped. The earliest cookie
// expiry becomes PlayStream.expiresAt, so the player refreshes
// before the grant dies.
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
        value.range(of: #"^(?:user/[1-9][0-9]{0,18}|ch[1-9][0-9]{0,18})$"#, options: .regularExpression) != nil
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
        // Ref NiconicoApi.watchData: a channel's supplier has no
        // icons — a channel's room shows the channel's icon
        // (socialGroup.thumbnailImageUrl), as its list card does.
        // The old code read only the supplier icons, so channel
        // rooms showed a blank avatar on the detail page.
        let social = data["socialGroup"]
        let channelAvatar: String?
        if social["type"].stringValue == "channel" {
            channelAvatar = Self.publicImage(social["thumbnailImageUrl"].stringValue)
        } else {
            channelAvatar = nil
        }
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
            avatarURL: Self.publicImage(supplier["icons"]["uri150x150"].stringValue) ?? channelAvatar
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

    /// Only https artwork on niconico's own image hosts
    /// (ref NiconicoApi.publicImage: no port, credentials or
    /// fragment either — a link with any of those is dropped,
    /// not the room).
    static func publicImage(_ value: String?) -> String? {
        guard let value, value.count <= 8192,
              let uri = URL(string: value), uri.scheme == "https",
              uri.user == nil, uri.password == nil, uri.port == nil, uri.fragment == nil,
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

/// One media cookie of a stream grant (ref NiconicoApi.
/// NiconicoCookie): name/value/path, plus the expiry when the
/// server sent one.
struct NiconicoCookie {
    let name: String
    let value: String
    let path: String
    let expires: Date?
}

/// One revocable stream grant: the seat's `stream` message
/// (ref NiconicoApi.NiconicoGrant). The HLS master and every
/// playlist, segment and key below it need the cookies of their
/// own path on the media origin. A later `stream` message or
/// the seat's end revokes the grant; its cookies are dropped
/// with it.
struct NiconicoGrant {
    let masterURL: URL
    let cookies: [NiconicoCookie]

    /// The `Cookie` header for `target` at `now` (ref NiconicoGrant.
    /// cookieHeaderFor): the unexpired cookies whose path is
    /// `target`'s path or a parent of it, on exactly the master's
    /// origin, longest path first, then in the order received;
    /// nil when none applies.
    func cookieHeader(for target: URL, at now: Date = Date()) -> String? {
        guard target.scheme == "https", target.host == masterURL.host else { return nil }
        let matching = cookies.enumerated().filter { pair in
            let cookie = pair.element
            return (cookie.expires == nil || cookie.expires! > now)
                && Self.pathMatches(request: target.path, cookie: cookie.path)
        }.sorted { a, b in
            if a.element.path.count != b.element.path.count {
                return a.element.path.count > b.element.path.count
            }
            return a.offset < b.offset
        }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.element.name)=\($0.element.value)" }.joined(separator: "; ")
    }

    /// The earliest expiry among the grant's cookies, if any —
    /// the PlayStream.expiresAt the player refreshes before.
    var earliestExpiry: Date? { cookies.compactMap(\.expires).min() }

    static func pathMatches(request: String, cookie: String) -> Bool {
        request == cookie
            || (request.hasPrefix(cookie)
                && (cookie.hasSuffix("/") || request.dropFirst(cookie.count).hasPrefix("/")))
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
    /// testable without the network. Order is the reference's
    /// (ref NiconicoApi.qualities): height, then width, then
    /// bandwidth, highest first.
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
            let wa = Int($0.resolution.split(separator: "x").first ?? "0") ?? 0
            let wb = Int($1.resolution.split(separator: "x").first ?? "0") ?? 0
            if wa != wb { return wa > wb }
            return $0.bandwidth > $1.bandwidth
        }
        return variants
    }

    /// Validate a "stream" message into a grant (ref NiconicoApi.
    /// grant): https master URI on livedelivery.dlive.nicovideo.jp
    /// + its cookies. `quality` must be one of `availableQualities`
    /// (1–32 distinct names); at most 64 cookies, each a token name
    /// (not `__Host-`), a printable value without `;`, `"` or `\`,
    /// a `/hls/…` path, domain `nicovideo.jp`, secure, `expires`
    /// null or an HTTP date, no name twice on one path. Cookies
    /// already expired at `now` are dropped, not fatal.
    static func grant(fromStream data: JSONValue, now: Date = Date()) throws -> NiconicoGrant {
        guard data["protocol"].stringValue == "hls",
              let rawURI = data["uri"].stringValue,
              let uri = URL(string: rawURI),
              uri.scheme == "https",
              uri.host == "livedelivery.dlive.nicovideo.jp",
              uri.path.hasPrefix("/hls/playlists/"),
              uri.path.hasSuffix(".m3u8") else {
            throw LiveSiteError.invalidResponse
        }
        let quality = data["quality"].stringValue
        let qualities = data["availableQualities"].arrayValue.compactMap(\.stringValue)
        guard let quality, !quality.isEmpty, qualities.count >= 1, qualities.count <= 32,
              Set(qualities).count == qualities.count, qualities.contains(quality),
              quality.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil,
              qualities.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil }) else {
            throw LiveSiteError.invalidResponse
        }
        let rawCookies = data["cookies"].arrayValue
        guard rawCookies.count <= 64 else { throw LiveSiteError.invalidResponse }
        var cookies: [NiconicoCookie] = []
        var seen = Set<String>()
        for entry in rawCookies {
            guard let cookie = try cookie(from: entry, now: now) else { continue }
            guard seen.insert("\(cookie.path)\n\(cookie.name)").inserted else {
                throw LiveSiteError.invalidResponse
            }
            cookies.append(cookie)
        }
        return NiconicoGrant(masterURL: uri, cookies: cookies)
    }

    /// Validate one stream-grant cookie row. Returns the cookie,
    /// nil when it is already expired (dropped), throws when the
    /// row is malformed.
    static func cookie(from entry: JSONValue, now: Date = Date()) throws -> NiconicoCookie? {
        guard let name = entry["name"].stringValue,
              name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
              !name.hasPrefix("__Host-"),
              let value = entry["value"].stringValue,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }),
              !value.contains(";"), !value.contains("\""), !value.contains("\\"),
              let path = entry["path"].stringValue,
              path.range(of: #"^/hls/[A-Za-z0-9_/-]+$"#, options: .regularExpression) != nil,
              let domain = entry["domain"].stringValue,
              domain == "nicovideo.jp" || domain == ".nicovideo.jp",
              entry["secure"].boolValue == true else {
            throw LiveSiteError.invalidResponse
        }
        var expires: Date?
        if let rawExpires = entry["expires"].stringValue {
            guard let date = Self.parseHTTPDate(rawExpires) else {
                throw LiveSiteError.invalidResponse
            }
            expires = date
        }
        if let expires, expires <= now { return nil }
        return NiconicoCookie(name: name, value: value, path: path, expires: expires)
    }

    /// An RFC 1123 HTTP date (`Mon, 28 Sep 2026 18:41:00 GMT`) in
    /// UTC, or nil (ref NiconicoApi.parseHttpDate). The weekday is
    /// stripped before parsing: it carries no information, and a
    /// mismatched weekday must not fail a cookie.
    static func parseHTTPDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let rest: String
        if let comma = trimmed.firstIndex(of: ",") {
            rest = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        } else {
            rest = trimmed
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: rest)
    }
}

#if !os(Linux)
extension NiconicoMaster {
    /// Read the master playlist of the session's current grant
    /// (ref NiconicoSite.discoverPlayQualitiesRaw: the master with
    /// the seat's cookies for its path, 5 s budget). The seat stays
    /// open — only NiconicoSite closes it when playback ends.
    static func fetchVariants(session: NiconicoSession, http: HTTPClient) async throws -> [NiconicoVariant] {
        guard let grant = session.currentGrant else { throw LiveSiteError.invalidResponse }
        var headers = [
            "User-Agent": "Mozilla/5.0",
            "Origin": origin,
            "Referer": "\(origin)/watch/\(session.programID)",
        ]
        if let cookie = grant.cookieHeader(for: grant.masterURL) {
            headers["Cookie"] = cookie
        }
        let data = try await http.get(grant.masterURL.absoluteString, headers: headers, timeout: 5)
        guard let text = String(data: data, encoding: .utf8) else { throw LiveSiteError.invalidResponse }
        return parseVariants(text, baseURL: grant.masterURL)
    }
}

/// A held niconico watch seat (ref NiconicoSeat,
/// niconico_seat.dart): the WebSocket stays open for the whole
/// playback. keepSeat is sent every keepIntervalSec (and on ping,
/// together with pong); a later `stream` message replaces the
/// grant; error / disconnect / 90 s of silence ends the seat.
/// The owner (NiconicoSite) closes it when playback ends —
/// closing the seat revokes the grant, so a closed seat's
/// cookies must not be used again.
final class NiconicoSession: @unchecked Sendable {
    let programID: String
    private let socket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var _grant: NiconicoGrant?
    private var _keepInterval: TimeInterval = 30
    private var _closed = false
    private var _ended = false
    private var _lastMessageAt = Date()
    private var _tasks: [Task<Void, Never>] = []

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !_closed && !_ended
    }

    var currentGrant: NiconicoGrant? {
        lock.lock(); defer { lock.unlock() }
        return _closed || _ended ? nil : _grant
    }

    var earliestExpiry: Date? { currentGrant?.earliestExpiry }

    func cookieHeader(for url: URL) -> String? {
        currentGrant?.cookieHeader(for: url)
    }

    private init(programID: String, socket: URLSessionWebSocketTask) {
        self.programID = programID
        self.socket = socket
    }

    /// Open a seat for an allowed, on-air program and wait for its
    /// first grant (ref NiconicoSeat.open, startup timeout 20 s).
    /// Throws when the program is not watchable anonymously.
    static func open(watch: NiconicoWatch) async throws -> NiconicoSession {
        guard watch.status == .onAir else { throw LiveSiteError.message("该节目未开播") }
        guard watch.access == .allowed else {
            switch watch.access {
            case .loginRequired: throw LiveSiteError.message("该节目需要登录后才能观看")
            case .regionRestricted: throw LiveSiteError.message("该节目在当前地区无法观看")
            default: throw LiveSiteError.message("该节目暂时无法观看")
            }
        }
        guard let socketURL = watch.webSocketURL, let frontendID = watch.frontendID else {
            throw LiveSiteError.invalidResponse
        }
        var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "frontend_id", value: String(frontendID)))
        components?.queryItems = items
        guard let url = components?.url else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("https://live.nicovideo.jp", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        let session = NiconicoSession(programID: watch.programID, socket: socket)
        do {
            try await socket.send(.string(Self.startWatchingMessage))
            try await socket.send(.string(Self.getAkashicMessage))
            try await session.waitForFirstGrant()
        } catch {
            socket.cancel(with: .normalClosure, reason: nil)
            throw error
        }
        session.startBackgroundLoops()
        return session
    }

    private static let startWatchingMessage = """
        {"type":"startWatching","data":{"stream":{"quality":"abr","protocol":"hls","latency":"high","chasePlay":false},"room":{"protocol":"webSocket","commentable":false},"reconnect":false}}
        """
    private static let getAkashicMessage = """
        {"type":"getAkashic","data":{"chasePlay":false}}
        """

    /// Wait for the seat + stream messages (ref NiconicoSeat.open:
    /// 20 s startup timeout). Answers ping with pong. Incoming
    /// frames queue in the socket, so nothing is lost when the
    /// background loops start afterwards.
    private func waitForFirstGrant() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var hasSeat = false
                while true {
                    let message = try await self.socket.receive()
                    self.noteMessage()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let json = JSONValue.parse(data) else { continue }
                    switch json["type"].stringValue {
                    case "ping":
                        self.send("{\"type\":\"pong\"}")
                        self.sendKeepSeat()
                    case "seat":
                        if let seconds = json["data"]["keepIntervalSec"].intValue,
                           seconds >= 1, seconds <= 300 {
                            self.setKeepInterval(TimeInterval(seconds))
                        }
                        hasSeat = true
                    case "stream":
                        guard hasSeat else { continue }
                        let grant = try NiconicoMaster.grant(fromStream: json["data"])
                        self.setGrant(grant)
                        return
                    case "error":
                        throw Self.seatError(json["data"])
                    case "disconnect":
                        throw LiveSiteError.message("该节目已结束")
                    default:
                        continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw LiveSiteError.networkUnavailable
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// The failure an `error` message reports, by `code`
    /// (ref NiconicoApi.seatError; HAoLive has no rate-limit
    /// error case, so too many connections is a message).
    private static func seatError(_ data: JSONValue) -> LiveSiteError {
        switch data["code"].stringValue {
        case "NO_PERMISSION", "NOT_PLAYABLE", "TICKET_REQUIRED":
            return .message("该节目需要登录后才能观看")
        case "TOO_MANY_CONNECTIONS", "CONNECT_ERROR":
            return .message("连接数过多，请稍后再试")
        case "INVALID_STREAM_QUALITY", "INVALID_MESSAGE":
            return .invalidResponse
        default:
            return .message("该节目暂时无法观看")
        }
    }

    /// Receive loop + keep-alive + silence watchdog for the whole
    /// playback (ref NiconicoSeat: keepSeat every keepIntervalSec,
    /// ping answered with pong and one more keepSeat, 90 s of
    /// silence ends the seat).
    private func startBackgroundLoops() {
        let receive = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.socket.receive()
                    self.noteMessage()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let json = JSONValue.parse(data) else { continue }
                    switch json["type"].stringValue {
                    case "ping":
                        self.send("{\"type\":\"pong\"}")
                        self.sendKeepSeat()
                    case "seat":
                        if let seconds = json["data"]["keepIntervalSec"].intValue,
                           seconds >= 1, seconds <= 300 {
                            self.setKeepInterval(TimeInterval(seconds))
                        }
                    case "stream":
                        if let grant = try? NiconicoMaster.grant(fromStream: json["data"]) {
                            self.setGrant(grant)
                        }
                    case "error", "disconnect":
                        self.markEnded()
                        return
                    default:
                        continue
                    }
                } catch {
                    self.markEnded()
                    return
                }
            }
        }
        let keepAlive = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.keepInterval()))
                guard !Task.isCancelled, self.isAlive else { break }
                self.sendKeepSeat()
            }
        }
        let watchdog = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, self.isAlive else { break }
                let silent: Bool = {
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return Date().timeIntervalSince(self._lastMessageAt) > 90
                }()
                if silent {
                    self.markEnded()
                    break
                }
            }
        }
        lock.lock()
        _tasks = [receive, keepAlive, watchdog]
        lock.unlock()
    }

    /// Ends the seat: timers stop, the grant is revoked and the
    /// socket is closed (ref NiconicoSeat.close). Idempotent.
    func close() {
        let tasks: [Task<Void, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            if _closed { return [] }
            _closed = true
            _grant = nil
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

    private func noteMessage() {
        lock.lock()
        _lastMessageAt = Date()
        lock.unlock()
    }

    private func setGrant(_ grant: NiconicoGrant) {
        lock.lock()
        _grant = grant
        lock.unlock()
    }

    private func setKeepInterval(_ interval: TimeInterval) {
        lock.lock()
        _keepInterval = interval
        lock.unlock()
    }

    private func keepInterval() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _keepInterval
    }

    private func send(_ text: String) {
        Task { try? await self.socket.send(.string(text)) }
    }

    private func sendKeepSeat() {
        send("{\"type\":\"keepSeat\"}")
    }
}
#endif
