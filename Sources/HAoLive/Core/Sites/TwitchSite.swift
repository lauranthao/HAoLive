// TwitchSite.swift
// HAo Live — real Twitch adapter (anonymous, no login).
// Pure Live's route (lib/shared/platforms/twitch/twitch_site.dart),
// re-implemented from scratch for HAo Live. Every endpoint below was
// verified live from this VM 2026-11-28 (all HTTP 200, no login):
//   categories  POST gql.twitch.tv/gql  SearchCategoryTags (not used
//               for the flat list — see below) / BrowsePage_AllDirectories
//               (hash 2f67f71b…, limit 100, sort VIEWER_COUNT) ->
//               data.directoriesWithTags.edges[].node
//               {id, slug, displayName, avatarURL, viewersCount}
//               Categories ARE the games: HAoLive has a flat category
//               model, so each game is one LiveCategory
//               (id "twitch-<slug>"); the tag tree Pure Live builds
//               (SearchCategoryTags -> per-tag BrowsePage) is flattened
//               away, not dropped — the same games come back.
//   recommend   DirectoryPage_Game slug "just-chatting" (see below).
//   directory   POST gql  DirectoryPage_Game (hash 76cb069d…,
//               slug + VIEWER_COUNT + cursor paging) ->
//               data.game.streams.edges[].node {title, viewersCount,
//               previewImageURL, broadcaster{login, displayName,
//               profileImageURL, id}, game{displayName}}
//   search      POST gql  SearchResultsPage_SearchResults
//               (hash 7f3580f6…) -> data.searchFor.channels.edges[]
//               .item {login, displayName, profileImageURL,
//               broadcastSettings.title, followers.totalCount,
//               stream{viewersCount, previewImageURL, game}}
//   detail      batched POST gql  [ChannelShell (fea4573a…),
//               StreamMetadata (b57f9b91…)] -> userOrError
//               {displayName, profileImageURL, stream.viewersCount}
//               + user {stream{type, createdAt, game},
//               lastBroadcast.title}. NOTE (verified live): the
//               StreamMetadata stream carries NO viewersCount and NO
//               previewImageURL — viewers come from the ChannelShell
//               stream, the title from lastBroadcast, and the cover
//               falls back to the profile image when offline.
//   play        POST gql  PlaybackAccessToken (ed230aa1…,
//               {isLive:true, login, playerType:"site"}) ->
//               value + signature -> GET usher.ttvnw.net/api/channel/
//               hls/{login}.m3u8?sig=&token=&allow_source=true… ->
//               master m3u8; each #EXT-X-STREAM-INF + following URI is
//               one quality (VIDEO="chunked" is source/原画). Variant
//               URLs are absolute https and carry their own signing
//               material — they are used verbatim, never re-signed or
//               re-built. Verified live: 5 variants for qttsix
//               (1080p60 source … 160p30).
//   danmaku     Twitch IRC (TwitchDanmaku.swift), anonymous justinfan.
//               Verified live: 001 welcome + JOIN + PRIVMSG with tags.
//
// Client-ID: kimne78kx3ncx6brgo4mv6wki5h1ko is the Twitch WEB
// PLAYER's public client identifier (the same value Twitch's own
// web player sends; Pure Live carries it openly). It is NOT an
// account key, NOT a secret, and identifies no user — it only says
// "a web client". No other fixed key/secret is used anywhere here.
//
// Client-Integrity risk (read this before trusting Twitch): Twitch
// may demand a Client-Integrity token (POST gql.twitch.tv/integrity,
// bound to Device-Id). Pure Live mints it through Android native TLS
// or a Chromium fallback — NEITHER exists on iOS. This adapter tries
// the plain request first, then the /integrity endpoint once, then
// gives up with the server's own error. On 2026-11-28 the plain
// request worked from this VM for every operation above, so the
// integrity path is currently untested live — if Twitch starts
// enforcing it, the whole platform goes dark until a device-side
// minting path exists. That is a real, known limitation, not a
// solved problem.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TwitchSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .twitch
    private let http = HTTPClient.shared

    private static let gqlURL = "https://gql.twitch.tv/gql"
    private static let integrityURL = "https://gql.twitch.tv/integrity"
    private static let webBase = "https://www.twitch.tv"
    private static let chromeUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"

    /// Twitch web player's public client identifier — see the file
    /// header. Not an account key, not a secret.
    private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    private static let hashSearchCategoryTags = "b4cb189d8d17aadf29c61e9d7c7e7dcfc932e93b77b3209af5661bffb484195f"
    private static let hashBrowseDirectories = "2f67f71ba89f3c0ed26a141ec00da1defecb2303595f5cda4298169549783d9e"
    private static let hashDirectoryGame = "76cb069d835b8a02914c08dc42c421d0dafda8af5b113a3f19141824b901402f"
    private static let hashSearchResults = "7f3580f6ac6cd8aa1424cff7c974a07143827d6fa36bba1b54318fe7f0b68dc5"
    private static let hashChannelShell = "fea4573a7bf2644f5b3f2cbbdcbee0d17312e48d2e55f080589d053aad353f11"
    private static let hashStreamMetadata = "b57f9b910f8cd1a4659d894fe7550ccc81ec9052c01e438b290fd66a040b9b93"
    private static let hashPlaybackAccessToken = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"

    private static let playSessionIDs = ["bdd22331a986c7f1073628f2fc5b19da", "064bc3ff1722b6f53b0b5b8c01e46ca5"]

    /// One random 32-hex Device-Id per site instance (Pure Live's
    /// generateDeviceId). Stable for the process so the integrity
    /// token, when minted, stays bound to the same device.
    private let deviceID: String = TwitchSite.generateDeviceID()

    /// Client-Integrity token minted from /integrity, if any, and
    /// when it expires. Nil until the first integrity error.
    private var integrityToken: String?
    private var integrityExpiresAt: Date?

    /// Paging cursors, keyed "kind|id|page" (the cursor for page N+1
    /// is stored under page N's key when page N is read).
    private var cursors: [String: String] = [:]

    // MARK: - Headers / transport

    private func gqlHeaders() -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.chromeUA,
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "application/vnd.twitchtv.v5+json",
            "Client-ID": Self.clientID,
            "Device-Id": deviceID,
            "Origin": Self.webBase,
            "Referer": "\(Self.webBase)/",
        ]
        if let token = integrityToken, !token.isEmpty,
           let expiry = integrityExpiresAt, expiry > Date().addingTimeInterval(30) {
            headers["Client-Integrity"] = token
        }
        return headers
    }

    /// One persisted-query request body (single operation).
    static func persistedRequest(operation: String, hash: String, variables: [String: Any]) -> Data? {
        let body: [String: Any] = [
            "operationName": operation,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
            "variables": variables,
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// POST one GQL body; on an integrity error, mint a token from
    /// /integrity once and retry once. Throws the server's own
    /// GraphQL error message when the envelope carries one.
    private func gql(_ body: Data) async throws -> JSONValue {
        var response = try await http.postJSONParsed(Self.gqlURL, jsonData: body, headers: gqlHeaders())
        if Self.hasIntegrityError(response) {
            integrityToken = nil
            integrityExpiresAt = nil
            try? await refreshIntegrityToken()
            response = try await http.postJSONParsed(Self.gqlURL, jsonData: body, headers: gqlHeaders())
        }
        if let message = Self.graphQLError(response) {
            throw LiveSiteError.message(message)
        }
        return response
    }

    /// POST a batch body (a JSON array of persisted requests).
    private func gqlBatch(_ body: Data) async throws -> JSONValue {
        var response = try await http.postJSONParsed(Self.gqlURL, jsonData: body, headers: gqlHeaders())
        if Self.hasIntegrityError(response) {
            integrityToken = nil
            integrityExpiresAt = nil
            try? await refreshIntegrityToken()
            response = try await http.postJSONParsed(Self.gqlURL, jsonData: body, headers: gqlHeaders())
        }
        return response
    }

    /// Mint a Client-Integrity token from /integrity (Twitch's web
    /// flow: X-Device-Id instead of Device-Id, no Client-Integrity
    /// header on the minting call itself). Throws when the endpoint
    /// does not return a usable token — the caller then fails with
    /// the original integrity error instead of a fake success.
    private func refreshIntegrityToken() async throws {
        guard let url = URL(string: Self.integrityURL) else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(Self.chromeUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.twitchtv.v5+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientID, forHTTPHeaderField: "Client-ID")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(Self.webBase, forHTTPHeaderField: "Origin")
        request.setValue("\(Self.webBase)/", forHTTPHeaderField: "Referer")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = JSONValue.parse(data),
              let token = json["token"].stringValue, !token.isEmpty,
              let expiry = Self.normalizeIntegrityExpiry(json["expiration"]) else {
            throw LiveSiteError.message("Twitch 完整性校验失败")
        }
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiry) / 1000)
        guard expiresAt > Date() else { throw LiveSiteError.message("Twitch 完整性校验失败") }
        integrityToken = token
        integrityExpiresAt = expiresAt
    }

    /// The integrity endpoint exposes expiration as Unix seconds in
    /// some captures and milliseconds in others; accept both.
    static func normalizeIntegrityExpiry(_ value: JSONValue) -> Int? {
        guard let parsed = value.intValue, parsed > 0 else { return nil }
        return parsed < 100_000_000_000 ? parsed * 1000 : parsed
    }

    /// True when a GQL envelope (or batch) reports an integrity failure.
    static func hasIntegrityError(_ response: JSONValue) -> Bool {
        if !response.arrayValue.isEmpty {
            return response.arrayValue.contains { hasIntegrityError($0) }
        }
        for error in response["errors"].arrayValue {
            let message = (error["message"].stringValue ?? "").lowercased()
            if message.contains("failed integrity check") || message.contains("integrity token") {
                return true
            }
        }
        return false
    }

    /// First GraphQL error message in an envelope, if any.
    static func graphQLError(_ response: JSONValue) -> String? {
        if !response.arrayValue.isEmpty {
            for item in response.arrayValue {
                if let message = graphQLError(item) { return message }
            }
            return nil
        }
        for error in response["errors"].arrayValue {
            if let message = error["message"].stringValue, !message.isEmpty { return message }
        }
        return nil
    }

    static func generateDeviceID() -> String {
        let hex = Array("0123456789abcdef")
        return (0..<32).map { _ in String(hex[Int.random(in: 0..<16)]) }.joined()
    }

    private func cursorKey(_ kind: String, _ id: String, _ page: Int) -> String {
        "\(kind)|\(id)|\(page)"
    }

    private func cursor(for kind: String, id: String, page: Int) -> String {
        cursors[cursorKey(kind, id, page)] ?? ""
    }

    private func saveCursor(_ value: String, kind: String, id: String, page: Int, hasNextPage: Bool) {
        cursors[cursorKey(kind, id, page + 1)] = hasNextPage ? value : ""
    }

    // MARK: - Categories (games)

    func categories() async throws -> [LiveCategory] {
        guard let body = Self.persistedRequest(
            operation: "BrowsePage_AllDirectories",
            hash: Self.hashBrowseDirectories,
            variables: [
                "limit": 100,
                "options": [
                    "recommendationsContext": ["platform": "web"],
                    "requestID": "JIRA-VXP-2397",
                    "sort": "VIEWER_COUNT",
                    "tags": [] as [String],
                ] as [String: Any],
            ]
        ) else { throw LiveSiteError.invalidResponse }
        let response = try await gql(body)
        return Self.categories(fromBrowseResponse: response)
    }

    /// Pure parser for BrowsePage_AllDirectories. Testable without
    /// the network.
    static func categories(fromBrowseResponse response: JSONValue) -> [LiveCategory] {
        response["data"]["directoriesWithTags"]["edges"].arrayValue.compactMap { edge in
            let node = edge["node"]
            guard let slug = node["slug"].stringValue, !slug.isEmpty,
                  let name = node["displayName"].stringValue, !name.isEmpty else { return nil }
            return LiveCategory(
                id: "twitch-\(slug)",
                platform: .twitch,
                name: name,
                iconName: nil,
                iconURL: Self.imageURL(node["avatarURL"].stringValue)
            )
        }
    }

    // MARK: - Lists

    func recommendRooms() async throws -> [LiveRoom] {
        try await recommendRooms(page: 1)
    }

    /// Recommended = the Just Chatting directory (Pure Live's
    /// getRecommendRooms).
    func recommendRooms(page: Int) async throws -> [LiveRoom] {
        try await directoryRooms(slug: "just-chatting", page: page)
    }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] {
        try await categoryRooms(category, page: 1)
    }

    func categoryRooms(_ category: LiveCategory, page: Int) async throws -> [LiveRoom] {
        let slug = category.id.hasPrefix("twitch-") ? String(category.id.dropFirst("twitch-".count)) : category.id
        return try await directoryRooms(slug: slug, page: page)
    }

    private func directoryRooms(slug: String, page: Int, pageSize: Int = 30) async throws -> [LiveRoom] {
        let cursor = cursor(for: "directory", id: slug, page: page)
        if cursor.isEmpty && page > 1 { return [] }
        var variables: [String: Any] = [
            "imageWidth": 50,
            "slug": slug,
            "options": [
                "sort": "VIEWER_COUNT",
                "recommendationsContext": ["platform": "web"],
                "requestID": "JIRA-VXP-2397",
                "freeformTags": NSNull(),
                "tags": [] as [String],
                "broadcasterLanguages": ["ZH", "KO"],
                "systemFilters": [] as [String],
            ] as [String: Any],
            "sortTypeIsRecency": false,
            "limit": pageSize,
            "includeCostreaming": true,
        ]
        if !cursor.isEmpty { variables["cursor"] = cursor }
        guard let body = Self.persistedRequest(
            operation: "DirectoryPage_Game",
            hash: Self.hashDirectoryGame,
            variables: variables
        ) else { throw LiveSiteError.invalidResponse }
        // DirectoryPage_Game is sent as a one-element batch array.
        guard let batch = try? JSONSerialization.data(
            withJSONObject: [try JSONSerialization.jsonObject(with: body, options: [])],
            options: []
        ) else { throw LiveSiteError.invalidResponse }
        let response = try await gql(batch)
        let envelope = response[0]
        guard let streams = Self.connection(envelope["data"]["game"]["streams"]) else {
            if let message = Self.graphQLError(envelope) { throw LiveSiteError.message(message) }
            return []
        }
        let edges = streams.edges
        saveCursor(edges.last?["cursor"].stringValue ?? "", kind: "directory", id: slug, page: page, hasNextPage: streams.hasNextPage)
        return edges.compactMap { Self.room(fromDirectoryNode: $0["node"]) }
    }

    /// Read a GQL connection (edges + pageInfo.hasNextPage) without
    /// assuming pageInfo is present — Twitch sometimes omits it on a
    /// usable first page (Pure Live's parseConnection).
    static func connection(_ raw: JSONValue) -> (edges: [JSONValue], hasNextPage: Bool)? {
        guard !raw.isNull else { return nil }
        let edges = raw["edges"].arrayValue
        let hasNext = raw["pageInfo"]["hasNextPage"].boolValue ?? false
        return (edges, hasNext)
    }

    /// Pure parser for a DirectoryPage_Game node. Testable without
    /// the network.
    static func room(fromDirectoryNode node: JSONValue) -> LiveRoom? {
        let broadcaster = node["broadcaster"]
        guard let login = broadcaster["login"].stringValue, !login.isEmpty else { return nil }
        return LiveRoom(
            id: "twitch-\(login)",
            platform: .twitch,
            roomID: login,
            title: node["title"].stringValue ?? "",
            anchorName: broadcaster["displayName"].stringValue ?? login,
            anchorAvatarURL: Self.imageURL(broadcaster["profileImageURL"].stringValue),
            coverURL: Self.imageURL(node["previewImageURL"].stringValue),
            categoryName: node["game"]["displayName"].stringValue ?? node["game"]["name"].stringValue,
            viewerCount: node["viewersCount"].intValue ?? 0,
            isLive: true
        )
    }

    // MARK: - Search

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: 1)
    }

    func searchRooms(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await search(keyword: keyword, page: page)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword)
    }

    func searchAnchors(keyword: String, page: Int) async throws -> [LiveRoom] {
        try await searchRooms(keyword: keyword, page: page)
    }

    private func search(keyword: String, page: Int) async throws -> [LiveRoom] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cursor = cursor(for: "search", id: trimmed, page: page)
        if cursor.isEmpty && page > 1 { return [] }
        var variables: [String: Any] = [
            "platform": "web",
            "query": trimmed,
            "options": ["targets": NSNull(), "shouldSkipDiscoveryControl": false] as [String: Any],
            "requestID": "808c9f2e-f52e-431c-8dc7-d2e3c1831d77",
            "includeIsDJ": true,
        ]
        if !cursor.isEmpty { variables["cursor"] = cursor }
        guard let body = Self.persistedRequest(
            operation: "SearchResultsPage_SearchResults",
            hash: Self.hashSearchResults,
            variables: variables
        ) else { throw LiveSiteError.invalidResponse }
        let response = try await gql(body)
        let channels = response["data"]["searchFor"]["channels"]
        saveCursor(channels["cursor"].stringValue ?? "", kind: "search", id: trimmed, page: page, hasNextPage: !(channels["cursor"].stringValue ?? "").isEmpty)
        return channels["edges"].arrayValue.compactMap { Self.room(fromSearchItem: $0["item"]) }
    }

    /// Pure parser for a SearchResultsPage channel item. A null
    /// stream means the channel is offline (isLive false) — the
    /// channel is still a real search hit. Testable without the
    /// network.
    static func room(fromSearchItem node: JSONValue) -> LiveRoom? {
        guard let login = node["login"].stringValue, !login.isEmpty else { return nil }
        let stream = node["stream"]
        let isLive = !stream.isNull
        return LiveRoom(
            id: "twitch-\(login)",
            platform: .twitch,
            roomID: login,
            title: node["broadcastSettings"]["title"].stringValue ?? "",
            anchorName: node["displayName"].stringValue ?? login,
            anchorAvatarURL: Self.imageURL(node["profileImageURL"].stringValue),
            coverURL: Self.imageURL(isLive ? stream["previewImageURL"].stringValue : node["profileImageURL"].stringValue),
            categoryName: stream["game"]["displayName"].stringValue,
            viewerCount: stream["viewersCount"].intValue ?? 0,
            isLive: isLive
        )
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        let login = roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !login.isEmpty else { throw LiveSiteError.roomNotFound(roomID) }
        let shell = Self.persistedRequest(
            operation: "ChannelShell",
            hash: Self.hashChannelShell,
            variables: ["login": login]
        )
        let meta = Self.persistedRequest(
            operation: "StreamMetadata",
            hash: Self.hashStreamMetadata,
            variables: ["channelLogin": login, "includeIsDJ": true]
        )
        guard let shell, let meta,
              let shellObj = try? JSONSerialization.jsonObject(with: shell, options: []),
              let metaObj = try? JSONSerialization.jsonObject(with: meta, options: []),
              let batch = try? JSONSerialization.data(withJSONObject: [shellObj, metaObj], options: [])
        else { throw LiveSiteError.invalidResponse }
        let response = try await gqlBatch(batch)
        guard response.arrayValue.count >= 2 else { throw LiveSiteError.roomNotFound(roomID) }
        guard let room = Self.room(fromDetailBatch: response, fallbackLogin: login) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        return room
    }

    /// Pure parser for the [ChannelShell, StreamMetadata] batch.
    /// Returns nil when the channel does not exist. Testable without
    /// the network.
    static func room(fromDetailBatch response: JSONValue, fallbackLogin: String) -> LiveRoom? {
        let shellUser = response[0]["data"]["userOrError"]
        guard !shellUser.isNull, shellUser["__typename"].stringValue != "UserDoesNotExist" else { return nil }
        let metaUser = response[1]["data"]["user"]
        guard !metaUser.isNull else { return nil }
        let shellStream = shellUser["stream"]
        let metaStream = metaUser["stream"]
        let isLive = metaStream["type"].stringValue == "live"
        let viewers = shellStream["viewersCount"].intValue ?? metaStream["viewersCount"].intValue ?? 0
        let title = metaUser["lastBroadcast"]["title"].stringValue ?? ""
        let login = shellUser["login"].stringValue ?? fallbackLogin
        let avatar = shellUser["profileImageURL"].stringValue ?? metaUser["profileImageURL"].stringValue
        let game = metaStream["game"]["displayName"].stringValue ?? metaStream["game"]["name"].stringValue
        let preview = metaStream["previewImageURL"].stringValue
        return LiveRoom(
            id: "twitch-\(login)",
            platform: .twitch,
            roomID: login,
            title: title,
            anchorName: shellUser["displayName"].stringValue ?? login,
            anchorAvatarURL: Self.imageURL(avatar),
            coverURL: Self.imageURL(isLive ? (preview ?? avatar) : avatar),
            categoryName: game,
            viewerCount: isLive ? viewers : 0,
            isLive: isLive
        )
    }

    // MARK: - Play URLs (PlaybackAccessToken + usher master)

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        let login = room.roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !login.isEmpty else { return [] }
        guard let body = Self.persistedRequest(
            operation: "PlaybackAccessToken",
            hash: Self.hashPlaybackAccessToken,
            variables: [
                "isLive": true,
                "login": login,
                "isVod": false,
                "vodID": "",
                "playerType": "site",
                "isClip": false,
                "clipID": "",
                "platform": "site",
            ]
        ) else { throw LiveSiteError.invalidResponse }
        let response = try await gql(body)
        let access = response["data"]["streamPlaybackAccessToken"]
        guard let token = access["value"].stringValue, !token.isEmpty,
              let signature = access["signature"].stringValue, !signature.isEmpty else {
            return []
        }
        let masterURL = Self.usherURL(login: login, token: token, signature: signature)
        let data = try await http.get(masterURL, headers: ["User-Agent": Self.chromeUA])
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let headers = PlaybackHeaders.headers(platform: .twitch, roomID: login)
        return Self.streams(fromMasterPlaylist: text, headers: headers)
    }

    /// The usher URL. sig/token are percent-encoded with a strict
    /// encoder: URLComponents would leave "+" unencoded, which a
    /// form-style parser reads as a space and breaks the signature.
    static func usherURL(login: String, token: String, signature: String) -> String {
        let sessionID = playSessionIDs.randomElement() ?? playSessionIDs[0]
        let params: [(String, String)] = [
            ("acmb", "e30="),
            ("allow_source", "true"),
            ("cdm", "wv"),
            ("fast_bread", "true"),
            ("p", String(Int.random(in: 0..<10_000_000))),
            ("platform", "web"),
            ("play_session_id", sessionID),
            ("player_backend", "mediaplayer"),
            ("player_version", "1.28.0-rc.1"),
            ("playlist_include_framerate", "true"),
            ("reassignments_supported", "true"),
            ("sig", signature),
            ("token", token),
            ("transcode_mode", "cbr_v1"),
        ]
        let query = params.map { "\($0.0)=\(Self.percentEncodeQueryValue($0.1))" }.joined(separator: "&")
        return "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8?\(query)"
    }

    /// Percent-encode a query value: everything except unreserved
    /// characters is encoded, so "+", "/" and "=" in signatures and
    /// tokens survive the trip.
    static func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Pure parser for a Twitch master playlist: each
    /// #EXT-X-STREAM-INF plus its following URI is one quality,
    /// best first (source first, then bandwidth descending).
    /// Testable without the network.
    static func streams(fromMasterPlaylist content: String, headers: [String: String]) -> [PlayStream] {
        var grouped: [String: (label: String, sort: Int, urls: [String])] = [:]
        var pending: [String: String]?
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = Self.parsePlaylistAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let attributes = pending else { continue }
            pending = nil
            guard line.hasPrefix("http://") || line.hasPrefix("https://"),
                  let url = URL(string: line) else { continue }
            let bandwidth = Int(attributes["BANDWIDTH"] ?? "") ?? 0
            let resolution = attributes["RESOLUTION"] ?? ""
            let height = Int(resolution.split(separator: "x").last.map(String.init) ?? "") ?? 0
            let frameRate = Double(attributes["FRAME-RATE"] ?? "") ?? 0
            let videoGroup = (attributes["VIDEO"] ?? "").lowercased()
            let isSource = videoGroup == "chunked"
            let label = Self.qualityName(bandwidth: bandwidth, height: height, frameRate: frameRate, isSource: isSource)
            let key = "\(height):\(Int(frameRate.rounded())):\(bandwidth):\(videoGroup)"
            if grouped[key] == nil {
                grouped[key] = (label, isSource ? Int.max : bandwidth, [url.absoluteString])
            } else if !grouped[key]!.urls.contains(url.absoluteString) {
                grouped[key]!.urls.append(url.absoluteString)
            }
        }
        return grouped.values
            .sorted { $0.sort > $1.sort }
            .flatMap { entry in
                entry.urls.compactMap { urlString in
                    guard let url = URL(string: urlString) else { return nil }
                    return PlayStream(url: url, quality: entry.label, line: "主线路", headers: headers)
                }
            }
    }

    /// Parse `KEY=value,KEY="quoted value"` playlist attributes.
    static func parsePlaylistAttributes(_ value: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            // Skip separators / whitespace.
            while i < chars.count && (chars[i] == "," || chars[i] == " ") { i += 1 }
            guard i < chars.count else { break }
            var key = ""
            while i < chars.count && chars[i] != "=" && chars[i] != "," {
                key.append(chars[i]); i += 1
            }
            guard i < chars.count, chars[i] == "=" else { break }
            i += 1
            var raw = ""
            if i < chars.count && chars[i] == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    raw.append(chars[i]); i += 1
                }
                if i < chars.count { i += 1 } // closing quote
            } else {
                while i < chars.count && chars[i] != "," {
                    raw.append(chars[i]); i += 1
                }
            }
            if !key.isEmpty { attributes[key] = raw }
        }
        return attributes
    }

    /// Pure Live's quality naming: "1080p60", source gets " (Source)"
    /// — in HAoLive the untouched source stream is labelled 原画.
    static func qualityName(bandwidth: Int, height: Int, frameRate: Double, isSource: Bool) -> String {
        if height > 0 {
            let fps = frameRate >= 45 ? "\(Int(frameRate.rounded()))" : ""
            if isSource { return "原画" }
            return "\(height)p\(fps)"
        }
        if isSource { return "原画" }
        if bandwidth > 5_000_000 { return "1080p" }
        if bandwidth > 2_500_000 { return "720p" }
        if bandwidth > 1_000_000 { return "480p" }
        if bandwidth > 500_000 { return "360p" }
        return "自动"
    }

    // MARK: - Danmaku

    func danmakuStream(roomID: String) -> AsyncStream<DanmakuItem> {
#if !os(Linux)
        return TwitchDanmaku.stream(roomID: roomID)
#else
        return AsyncStream { $0.finish() }
#endif
    }
}
