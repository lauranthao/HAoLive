// YoutubeSite.swift
// HAo Live — YouTube Live adapter (anonymous, no login).
//
// 形态：本平台无浏览列表与服务端搜索，只能粘贴链接/输入 ID 直达
// （视频链接、youtu.be 短链、频道 @handle / channel/UC… 链接，或直接贴
// 11 位 videoId）。categories() / recommendRooms() 一律返回 []，
// searchRooms() / searchAnchors() 只解析链接或 ID 得 videoId 再调详情，
// 解析不出返回 []，不假装有搜索。弹幕：无（LiveSite 默认空实现）。
//
// 详情/取流走 InnerTube（Pure Live lib/shared/platforms/youtube/
// youtube_api.dart 为准）：
//   ① GET https://www.youtube.com/watch?v={videoId}（Cookie SOCS=CAI），
//      从页内 ytInitialPlayerResponse 取 videoDetails / playabilityStatus，
//      并从页内 INNERTUBE_API_KEY 取当前网页端 key；
//   ② POST https://www.youtube.com/youtubei/v1/player?key={key}
//     （ANDROID 客户端，见 youtube_api.dart 的 room()），取
//      streamingData：hlsManifestUrl（拉 master 解析各分辨率档）、
//      formats（直链，各 qualityLabel）、dashManifestUrl（dash:auto）。
//   频道链接先解析成当前直播的 videoId（canonical 链接 → 页内
//   videoDetails.isLive → ytInitialData 里找 live videoId）。
//
// 关于 API key：这里用的 key 是 YouTube 网页端公开的客户端标识
// （INNERTUBE_API_KEY，YouTube 网页自己下发在每个 watch 页里，任何访客
// 打开页面都能看到；代码优先读页面上实时下发的 key，只有读不到时才用
// 与 Pure Live 参照相同的公开 fallback 值
// AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8）。它不是账号密钥、不是签名
// secret，不关联任何账号；不要把它当成凭证保管或轮换。
//
// 流地址带 expire 参数会过期：PlayStream.expiresAt 填该过期时间，
// 播放服务应在过期前 10 分钟刷新（Pure Live 的 getPlayUrlInvalidAt /
// getPlayUrlRefreshAt 做法）。流地址（含签名查询参数）原样保留，不拼接。
//
// 国内网络：YouTube 在中国大陆基本打不开，chen 的国内真机大概率看不了；
// 本适配器只保证在能访问 YouTube 的网络下工作。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class YoutubeSite: LiveSite, @unchecked Sendable {
    let platform: LivePlatform = .youtube
    private let http = HTTPClient.shared

    private static let origin = "https://www.youtube.com"

    /// Fallback InnerTube API key — the public web-client identifier
    /// YouTube ships in its own watch pages (see the file header:
    /// not an account key, not a secret). The live key is read from
    /// the fetched watch page first; this is only the fallback.
    private static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    private static let pageUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private static func pageHeaders(videoID: String?) -> [String: String] {
        [
            "User-Agent": pageUA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Cookie": "SOCS=CAI",
            "Referer": videoID.map { "\(origin)/watch?v=\($0)" } ?? "\(origin)/",
        ]
    }

    private static func mediaHeaders(videoID: String) -> [String: String] {
        [
            "user-agent": pageUA,
            "Referer": "\(origin)/watch?v=\(videoID)",
            "Origin": origin,
        ]
    }

    // MARK: - Lists (none: link-only platform)

    func categories() async throws -> [LiveCategory] { [] }

    func recommendRooms() async throws -> [LiveRoom] { [] }

    func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { [] }

    // MARK: - Search (link / ID only, no server search)

    func searchRooms(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    func searchAnchors(keyword: String) async throws -> [LiveRoom] {
        try await search(keyword: keyword)
    }

    private func search(keyword: String) async throws -> [LiveRoom] {
        guard let reference = Self.parseReference(keyword) else { return [] }
        guard let videoID = try? await resolveVideoID(reference) else { return [] }
        guard let detail = try? await fetchDetail(videoID: videoID) else { return [] }
        // A pasted link to an offline / restricted video is not a
        // playable room; do not list it as one.
        guard detail.isLive, !detail.restricted else { return [] }
        return [detail.room]
    }

    // MARK: - Room detail

    func roomDetail(roomID: String) async throws -> LiveRoom {
        guard let reference = Self.parseReference(roomID) else {
            throw LiveSiteError.roomNotFound(roomID)
        }
        let videoID = try await resolveVideoID(reference)
        return try await fetchDetail(videoID: videoID).room
    }

    // MARK: - Play URLs

    func playURLs(room: LiveRoom) async throws -> [PlayStream] {
        guard let reference = Self.parseReference(room.roomID) else { return [] }
        guard let videoID = try? await resolveVideoID(reference) else { return [] }
        let detail = try await fetchDetail(videoID: videoID)
        if detail.restricted, detail.isLive {
            // A live but restricted broadcast (members-only / sign-in
            // / age check): Pure Live reports the restriction instead
            // of an empty list, so the player shows a real message.
            throw LiveSiteError.message("该直播受限，无法匿名播放")
        }
        guard detail.isLive, !detail.restricted else { return [] }
        return try await Self.streams(fromStreamingData: detail.streamingData, videoID: videoID, http: http)
    }

    // MARK: - Detail fetch (page + InnerTube)

    private struct FetchedDetail {
        var room: LiveRoom
        var isLive: Bool
        var restricted: Bool
        var streamingData: JSONValue
    }

    /// Watch page + InnerTube player response, merged the way Pure
    /// Live's room() does (page videoDetails + API videoDetails,
    /// API playabilityStatus preferred). Testable without the network
    /// only through the static parsers below; the fetch itself needs
    /// YouTube reachable.
    private func fetchDetail(videoID: String) async throws -> FetchedDetail {
        let page = try await watchPage(videoID: videoID)
        let apiKey = Self.apiKey(fromPage: page) ?? Self.fallbackAPIKey
        let api = try await innerTube(videoID: videoID, apiKey: apiKey)
        return try Self.detail(videoID: videoID, pageHTML: page, api: api)
    }

    private func watchPage(videoID: String) async throws -> String {
        // Pure Live's YouTube timeout is 25 s (youtube_site.dart:
        // _timeout), not HTTPClient's 20 s default — the watch page
        // is ~1.4 MB and slow links need the extra headroom.
        let data = try await http.get("\(Self.origin)/watch?v=\(videoID)", headers: Self.pageHeaders(videoID: videoID), timeout: 25)
        guard let html = String(data: data, encoding: .utf8) else {
            throw LiveSiteError.invalidResponse
        }
        return html
    }

    private func innerTube(videoID: String, apiKey: String) async throws -> JSONValue {
        let body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "21.08.266",
                    "platform": "DESKTOP",
                    "clientScreen": "EMBED",
                    "clientFormFactor": "UNKNOWN_FORM_FACTOR",
                    "browserName": "Chrome",
                ],
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true],
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            throw LiveSiteError.invalidResponse
        }
        var headers = Self.pageHeaders(videoID: videoID)
        headers["Accept"] = "application/json"
        headers["Content-Type"] = "application/json"
        headers["Origin"] = Self.origin
        return try await http.postJSONParsed("\(Self.origin)/youtubei/v1/player?key=\(apiKey)", jsonData: data, headers: headers, timeout: 25)
    }

    /// Pure builder for the merged page + InnerTube payload.
    /// Throws roomNotFound when the video is gone / not a live video
    /// at all; returns isLive=false (not a throw) for an ended or
    /// upcoming stream, so the UI can show the offline state.
    private static func detail(videoID: String, pageHTML: String, api: JSONValue) throws -> FetchedDetail {
        let initialPlayer = extractObject(marker: "ytInitialPlayerResponse", in: pageHTML)
        let initialData = extractObject(marker: "ytInitialData", in: pageHTML)
        let apiDetails = api["videoDetails"]
        let initialDetails = initialPlayer?["videoDetails"] ?? .null
        // The API must agree this is the same video.
        if let actual = apiDetails["videoId"].stringValue, !actual.isEmpty, actual != videoID {
            throw LiveSiteError.roomNotFound(videoID)
        }
        let title = HaoText.firstNonEmpty(apiDetails["title"].stringValue, textValue(initialDetails["title"])) ?? ""
        let author = HaoText.firstNonEmpty(apiDetails["author"].stringValue, textValue(initialDetails["author"])) ?? ""
        guard !title.isEmpty, !author.isEmpty else { throw LiveSiteError.invalidResponse }
        let apiStatus = api["playabilityStatus"]
        let initialStatus = initialPlayer?["playabilityStatus"] ?? .null
        let status = !apiStatus["status"].stringValue.isNilOrEmpty ? apiStatus : initialStatus
        let statusCode = (status["status"].stringValue ?? "").uppercased()
        let reason = (status["reason"].stringValue ?? "").lowercased()
        let initialMicro = initialPlayer?["microformat"]["playerMicroformatRenderer"] ?? .null
        let apiMicro = api["microformat"]["playerMicroformatRenderer"]
        // Pure Live's video() merges page + player with the player
        // winning — the page microformat is only the fallback.
        let liveDetails = apiMicro["liveBroadcastDetails"].isNull ? initialMicro["liveBroadcastDetails"] : apiMicro["liveBroadcastDetails"]
        // Cover: player details first, then the page's, then either
        // microformat. The avatar is NOT this thumbnail — it is the
        // channel avatar from the page (see ownerAvatar below).
        let coverThumbnail = thumbnail(apiDetails["thumbnail"], initialDetails["thumbnail"], apiMicro["thumbnail"], initialMicro["thumbnail"])
        let isLive = apiDetails["isLive"].boolValue == true
            || initialDetails["isLive"].boolValue == true
            || liveDetails["isLiveNow"].boolValue == true
        let isLiveContent = isLive
            || apiDetails["isLiveContent"].boolValue == true
            || initialDetails["isLiveContent"].boolValue == true
            || apiDetails["isUpcoming"].boolValue == true
            || initialDetails["isUpcoming"].boolValue == true
            || !liveDetails.isNull
        let isPrivate = apiDetails["isPrivate"].boolValue == true || initialDetails["isPrivate"].boolValue == true
        let restricted = isPrivate
            || ["LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED"].contains(statusCode)
            || reason.contains("sign in")
            || reason.contains("private")
        if restricted {
            // Login / age / private: never presented as playable —
            // unless it is live right now. Pure Live's video() keeps
            // a live broadcast live with its restriction (and reports
            // the restriction at play time); only a non-live
            // restricted video is shown as not-live.
            let liveNow = isLive && statusCode != "LIVE_STREAM_OFFLINE"
            return FetchedDetail(
                room: room(videoID: videoID, title: title, author: author, thumbnail: coverThumbnail, avatar: ownerAvatar(in: initialData), category: microCategory(apiMicro, initialMicro), viewers: viewers(in: initialData), isLive: liveNow),
                isLive: liveNow, restricted: true, streamingData: api["streamingData"])
        }
        if isLive, statusCode != "LIVE_STREAM_OFFLINE" {
            // live (Pure Live: live unless the status says the stream
            // is offline — a live broadcast is live even when its
            // status is not OK, e.g. UNPLAYABLE).
        } else if isLiveContent || statusCode == "LIVE_STREAM_OFFLINE" {
            return FetchedDetail(
                room: room(videoID: videoID, title: title, author: author, thumbnail: coverThumbnail, avatar: ownerAvatar(in: initialData), category: microCategory(apiMicro, initialMicro), viewers: nil, isLive: false),
                isLive: false, restricted: false, streamingData: api["streamingData"])
        } else if statusCode.isEmpty {
            // No playability status at all and nothing live: Pure
            // Live calls this unknown, never "offline" — an ordinary
            // video is no room.
            throw LiveSiteError.roomNotFound(videoID)
        } else {
            throw LiveSiteError.roomNotFound(videoID)
        }
        return FetchedDetail(
            room: room(videoID: videoID, title: title, author: author, thumbnail: coverThumbnail, avatar: ownerAvatar(in: initialData), category: microCategory(apiMicro, initialMicro), viewers: viewers(in: initialData), isLive: true),
            isLive: true, restricted: false, streamingData: api["streamingData"])
    }

    private static func room(videoID: String, title: String, author: String, thumbnail: String?, avatar: String?, category: String?, viewers: Int?, isLive: Bool) -> LiveRoom {
        LiveRoom(
            id: "youtube-\(videoID)",
            platform: .youtube,
            roomID: videoID,
            title: title,
            anchorName: author,
            anchorAvatarURL: Self.imageURL(avatar),
            coverURL: Self.imageURL(thumbnail),
            categoryName: (category ?? "").isEmpty ? "YouTube Live" : category,
            viewerCount: viewers ?? 0,
            isLive: isLive
        )
    }

    // MARK: - Streams

    /// Pure Live's _streams: HLS master variants first (parsed),
    /// then direct formats, then dash:auto. Sorted best first.
    /// The HLS master fetch is the only network step here.
    static func streams(fromStreamingData streaming: JSONValue, videoID: String, http: HTTPClient) async throws -> [PlayStream] {
        var collected: [(height: Int, fps: Double, rank: Int, stream: PlayStream)] = []
        let headers = mediaHeaders(videoID: videoID)
        if let hlsRaw = streaming["hlsManifestUrl"].stringValue, !hlsRaw.isEmpty,
           let masterURL = URL(string: hlsRaw) {
            if let data = try? await http.get(hlsRaw, headers: headers, timeout: 25),
               let text = String(data: data, encoding: .utf8) {
                for variant in hlsVariants(masterURL: masterURL, text: text) {
                    guard let url = URL(string: variant.url) else { continue }
                    // Pure Live's label: height, plus the rounded
                    // frame rate when above 30.
                    let label = variant.height.map { h in "\(h)p\(variant.fps > 30 ? "\(Int(variant.fps.rounded()))" : "")" } ?? "HLS 自动"
                    let quality = variant.codec.isEmpty ? "\(label) · HLS" : "\(label) · \(variant.codec.uppercased()) · HLS"
                    collected.append((height: variant.height ?? 0, fps: variant.fps, rank: 30, stream: PlayStream(
                        url: url, quality: quality, line: "HLS", headers: headers,
                        expiresAt: expiry(of: variant.url))))
                }
            }
            if !collected.contains(where: { $0.stream.line == "HLS" }) {
                collected.append((height: 0, fps: 0, rank: 30, stream: PlayStream(
                    url: masterURL, quality: "HLS 自动 · HLS", line: "HLS", headers: headers,
                    expiresAt: expiry(of: hlsRaw))))
            }
        }
        // Pure Live's sources(): at most 64 progressive formats.
        for format in streaming["formats"].arrayValue.prefix(64) {
            guard let urlString = format["url"].stringValue, !urlString.isEmpty,
                  let label = format["qualityLabel"].stringValue, !label.isEmpty,
                  format["itag"].intValue != nil,
                  let url = URL(string: urlString) else { continue }
            let codec = codecName(format["mimeType"].stringValue ?? "")
            let quality = codec.isEmpty ? "\(label) · 直链" : "\(label) · \(codec.uppercased()) · 直链"
            collected.append((height: format["height"].intValue ?? 0, fps: format["fps"].doubleValue ?? 0, rank: 20, stream: PlayStream(
                url: url, quality: quality, line: "直链", headers: headers,
                expiresAt: expiry(of: urlString))))
        }
        if let dashRaw = streaming["dashManifestUrl"].stringValue, !dashRaw.isEmpty,
           let url = URL(string: dashRaw) {
            collected.append((height: 0, fps: 0, rank: 10, stream: PlayStream(
                url: url, quality: "DASH 自动 · DASH", line: "DASH", headers: headers,
                expiresAt: expiry(of: dashRaw))))
        }
        // Pure Live's qualitySort: height × 1000 + rounded fps +
        // protocol rank (HLS 30, progressive 20, DASH 10), best first.
        collected.sort {
            if $0.height != $1.height { return $0.height > $1.height }
            let leftFPS = Int($0.fps.rounded()), rightFPS = Int($1.fps.rounded())
            if leftFPS != rightFPS { return leftFPS > rightFPS }
            return $0.rank > $1.rank
        }
        return collected.map { $0.stream }
    }

    /// One HLS variant from a master playlist. Testable without the network.
    struct HLSVariant {
        var height: Int?
        var fps: Double
        var codec: String
        var url: String
    }

    static func hlsVariants(masterURL: URL, text: String) -> [HLSVariant] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { return [] }
        var out: [HLSVariant] = []
        var seen: Set<String> = []
        var pending: [String: String]?
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let attrs = pending else { continue }
            pending = nil
            var height: Int?
            if let res = attrs["RESOLUTION"],
               res.range(of: #"^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}$"#, options: .regularExpression) != nil,
               let x = res.firstIndex(of: "x") {
                height = Int(res[res.index(after: x)...])
            }
            let fps = Double(attrs["FRAME-RATE"] ?? "") ?? 0
            let codec = codecName(attrs["CODECS"] ?? "")
            guard let resolved = URL(string: line, relativeTo: masterURL)?.absoluteURL,
                  resolved.scheme == "https", Self.isMediaHost(resolved.host ?? "") else {
                // A variant off YouTube's media hosts: Pure Live
                // refuses the whole master (FormatException) and the
                // caller then offers the master itself as the
                // automatic source — so return no variants here.
                return []
            }
            // Pure Live's quality id (hls:<height>:<fps|0>:<codec>):
            // two variants of one id are ambiguous, keep the first.
            let id = "hls:\(height ?? 0):\(fps > 30 ? Int(fps.rounded()) : 0):\(codec.isEmpty ? "auto" : codec)"
            guard seen.insert(id).inserted else { continue }
            out.append(HLSVariant(height: height, fps: fps, codec: codec, url: resolved.absoluteString))
        }
        return out
    }

    /// YouTube media hosts (Pure Live's _mediaHost): googlevideo /
    /// youtube / youtube-nocookie, bare or subdomain, https only.
    static func isMediaHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "googlevideo.com" || value.hasSuffix(".googlevideo.com")
            || value == "youtube.com" || value.hasSuffix(".youtube.com")
            || value == "youtube-nocookie.com" || value.hasSuffix(".youtube-nocookie.com")
    }

    /// `KEY=value,KEY="quoted,value"` attribute list. Testable without the network.
    static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == "," || text[index] == " " { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            guard let eq = text[index...].firstIndex(of: "=") else { break }
            let key = String(text[index..<eq]).trimmingCharacters(in: .whitespaces)
            var valueIndex = text.index(after: eq)
            var value = ""
            if valueIndex < text.endIndex, text[valueIndex] == "\"" {
                valueIndex = text.index(after: valueIndex)
                while valueIndex < text.endIndex, text[valueIndex] != "\"" {
                    value.append(text[valueIndex])
                    valueIndex = text.index(after: valueIndex)
                }
                if valueIndex < text.endIndex { valueIndex = text.index(after: valueIndex) }
            } else {
                while valueIndex < text.endIndex, text[valueIndex] != "," {
                    value.append(text[valueIndex])
                    valueIndex = text.index(after: valueIndex)
                }
            }
            if !key.isEmpty { out[key] = value }
            index = valueIndex
        }
        return out
    }

    /// Pure Live's getPlayUrlInvalidAt: the `expire` query value (or
    /// /expire/<ts>/ path segment) is the UTC epoch second the signed
    /// URL dies. The service refreshes 10 minutes before this.
    /// Testable without the network.
    static func expiry(of urlString: String) -> Date? {
        guard let url = URL(string: urlString) else { return nil }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = comps.queryItems?.first(where: { $0.name == "expire" })?.value,
           let seconds = Int(value), seconds > 0 {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let segments = url.pathComponents
        if let index = segments.firstIndex(of: "expire"), index + 1 < segments.count,
           let seconds = Int(segments[index + 1]), seconds > 0 {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return nil
    }

    // MARK: - Link / ID parsing (Pure Live's youtube_link.dart)

    enum Reference {
        case video(String)
        case channel(String) // "@handle" or "channel/UC…" / "c/name" / "user/name"
    }

    /// Bare 11-char id, @handle, or any official YouTube watch /
    /// live / channel URL. Returns nil for anything else.
    static func parseReference(_ raw: String) -> Reference? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let id = normalizeVideoID(value) { return .video(id) }
        if value.hasPrefix("@") {
            guard let handle = normalizeHandle(String(value.dropFirst())) else { return nil }
            return .channel("@\(handle)")
        }
        let urlString = value.hasPrefix("http://") || value.hasPrefix("https://") ? value : "https://\(value)"
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              isOfficialHost(host) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        if host == "youtu.be" {
            guard segments.count == 1, let id = normalizeVideoID(segments[0]) else { return nil }
            return .video(id)
        }
        if segments.count == 1, segments[0] == "watch" {
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
                  let normalized = normalizeVideoID(id) else { return nil }
            return .video(normalized)
        }
        if segments.count == 2, segments[0].lowercased() == "embed", segments[1].lowercased() == "live_stream" {
            guard let channel = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "channel" })?.value,
                  channel.range(of: #"^UC[A-Za-z0-9_-]{20,30}$"#, options: .regularExpression) != nil else { return nil }
            return .channel("channel/\(channel)")
        }
        if segments.count == 2, ["live", "embed", "v"].contains(segments[0].lowercased()) {
            guard let id = normalizeVideoID(segments[1]) else { return nil }
            return .video(id)
        }
        guard let path = channelPath(segments) else { return nil }
        return .channel(path)
    }

    private static func channelPath(_ segments: [String]) -> String? {
        var values = segments
        if values.last?.lowercased() == "live" { values.removeLast() }
        guard !values.isEmpty, values.count <= 2 else { return nil }
        if values.count == 1, values[0].hasPrefix("@") {
            guard let handle = normalizeHandle(String(values[0].dropFirst())) else { return nil }
            return "@\(handle)"
        }
        guard values.count == 2 else { return nil }
        let prefix = values[0].lowercased()
        let id = values[1]
        if prefix == "channel", id.range(of: #"^UC[A-Za-z0-9_-]{20,30}$"#, options: .regularExpression) != nil {
            return "channel/\(id)"
        }
        if ["c", "user"].contains(prefix), id.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil {
            return "\(prefix)/\(id)"
        }
        return nil
    }

    static func normalizeVideoID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? value : nil
    }

    static func normalizeHandle(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, value.count <= 30,
              value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func isOfficialHost(_ host: String) -> Bool {
        host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    /// Channel reference -> the videoId of its current live stream.
    /// Fetches https://www.youtube.com/{channel}/live and reads, in
    /// order: canonical link, page videoDetails (isLive), then a
    /// bounded walk of ytInitialData for a live videoId.
    private func resolveVideoID(_ reference: Reference) async throws -> String {
        switch reference {
        case .video(let id): return id
        case .channel(let path):
            let url = "\(Self.origin)/\(path)/live"
            let data = try await http.get(url, headers: Self.pageHeaders(videoID: nil), timeout: 25)
            guard let html = String(data: data, encoding: .utf8) else {
                throw LiveSiteError.invalidResponse
            }
            if let id = Self.canonicalVideoID(in: html) { return id }
            if let player = Self.extractObject(marker: "ytInitialPlayerResponse", in: html) {
                let details = player["videoDetails"]
                if let id = Self.normalizeVideoID(details["videoId"].stringValue ?? ""), details["isLive"].boolValue == true {
                    return id
                }
            }
            if let initialData = Self.extractObject(marker: "ytInitialData", in: html),
               let id = Self.liveVideoID(in: initialData) {
                return id
            }
            throw LiveSiteError.roomNotFound(path)
        }
    }

    /// `<link rel="canonical" href="https://www.youtube.com/watch?v=…">`.
    /// Testable without the network.
    static func canonicalVideoID(in html: String) -> String? {
        guard let canonRange = html.range(of: "canonical") else { return nil }
        let tail = html[canonRange.upperBound...]
        guard let hrefRange = tail.range(of: "href=\"") else { return nil }
        let after = tail[hrefRange.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let href = String(after[..<end])
        guard let ref = parseReference(href), case .video(let id) = ref else { return nil }
        return id
    }

    /// Bounded walk for an object carrying a videoId with isLive /
    /// isLiveNow true (Pure Live's _findLiveVideoId, simplified:
    /// only the explicit live flags count, no badge-text scan).
    /// Testable without the network.
    static func liveVideoID(in json: JSONValue) -> String? {
        var budget = 250_000
        return walkLiveVideoID(json, depth: 0, budget: &budget)
    }

    private static func walkLiveVideoID(_ value: JSONValue, depth: Int, budget: inout Int) -> String? {
        guard depth <= 25 else { return nil }
        budget -= 1
        guard budget > 0 else { return nil }
        switch value {
        case .object(let dict):
            if let id = normalizeVideoID(dict["videoId"]?.stringValue ?? ""),
               dict["isLive"]?.boolValue == true || dict["isLiveNow"]?.boolValue == true {
                return id
            }
            for child in dict.values {
                if let found = walkLiveVideoID(child, depth: depth + 1, budget: &budget) { return found }
            }
            return nil
        case .array(let items):
            for child in items {
                if let found = walkLiveVideoID(child, depth: depth + 1, budget: &budget) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// Current viewers from a videoViewCountRenderer with isLive
    /// (Pure Live's _currentViewers). Nil when absent.
    /// Testable without the network.
    static func viewers(in json: JSONValue?) -> Int? {
        guard let json else { return nil }
        var budget = 250_000
        return walkViewers(json, depth: 0, budget: &budget)
    }

    private static func walkViewers(_ value: JSONValue, depth: Int, budget: inout Int) -> Int? {
        guard depth <= 25 else { return nil }
        budget -= 1
        guard budget > 0 else { return nil }
        switch value {
        case .object(let dict):
            if let renderer = dict["videoViewCountRenderer"], !renderer.isNull,
               renderer["isLive"].boolValue == true {
                let text = textValue(renderer["viewCount"]) ?? ""
                let digits = text.filter(\.isNumber)
                if let count = Int(digits) { return count }
            }
            for child in dict.values {
                if let found = walkViewers(child, depth: depth + 1, budget: &budget) { return found }
            }
            return nil
        case .array(let items):
            for child in items {
                if let found = walkViewers(child, depth: depth + 1, budget: &budget) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Small parsers

    /// `"INNERTUBE_API_KEY": "…"` from the watch page (manual scan:
    /// no capture groups needed). Nil when absent — the caller falls
    /// back to the public fallback key.
    /// Testable without the network.
    static func apiKey(fromPage html: String) -> String? {
        guard let marker = html.range(of: "INNERTUBE_API_KEY") else { return nil }
        let tail = html[marker.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let afterColon = tail[tail.index(after: colon)...]
        guard let open = afterColon.firstIndex(of: "\"") else { return nil }
        let afterOpen = afterColon[afterColon.index(after: open)...]
        guard let close = afterOpen.firstIndex(of: "\"") else { return nil }
        let key = String(afterOpen[..<close])
        return key.isEmpty ? nil : key
    }

    /// A plain JSON object following a marker in page HTML
    /// (ytInitialPlayerResponse / ytInitialData), via HuyaSite's
    /// brace matcher. Testable without the network.
    static func extractObject(marker: String, in html: String) -> JSONValue? {
        guard let markerRange = html.range(of: marker),
              let openIndex = html[markerRange.upperBound...].firstIndex(of: "{"),
              let text = HaoText.extractJSONObject(html, from: openIndex),
              let data = text.data(using: .utf8),
              let json = JSONValue.parse(data) else { return nil }
        return json
    }

    /// videoDetails title/author: plain string, or {simpleText} /
    /// {runs: [{text}]}. Testable without the network.
    static func textValue(_ value: JSONValue) -> String? {
        if let s = value.stringValue, !s.isEmpty { return s }
        if let s = value["simpleText"].stringValue, !s.isEmpty { return s }
        let runs = value["runs"].arrayValue.compactMap { $0["text"].stringValue }
        guard !runs.isEmpty else { return nil }
        return runs.joined()
    }

    /// Last usable thumbnail (largest) from a thumbnail object.
    /// Testable without the network.
    static func thumbnail(_ values: JSONValue..., avatar: Bool = false) -> String? {
        for value in values {
            let items = value["thumbnails"].arrayValue
            for item in items.reversed() {
                guard let raw = item["url"].stringValue, !raw.isEmpty,
                      let url = URL(string: raw), url.scheme == "https" else { continue }
                let host = url.host?.lowercased() ?? ""
                // Pure Live's _imageHost: ytimg / ggpht, bare or
                // subdomain; channel avatars also come from
                // googleusercontent.com.
                guard host == "ytimg.com" || host.hasSuffix(".ytimg.com")
                        || host == "ggpht.com" || host.hasSuffix(".ggpht.com")
                        || (avatar && (host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com"))) else { continue }
                return raw
            }
        }
        return nil
    }

    /// Channel avatar of a watch page (`videoOwnerRenderer.thumbnail`,
    /// Pure Live's _ownerAvatar). The room's avatar used to be the
    /// video thumbnail itself — a 16:9 still in a round avatar slot.
    /// Testable without the network.
    static func ownerAvatar(in json: JSONValue?) -> String? {
        guard let json else { return nil }
        var budget = 250_000
        return walkOwnerAvatar(json, depth: 0, budget: &budget)
    }

    private static func walkOwnerAvatar(_ value: JSONValue, depth: Int, budget: inout Int) -> String? {
        guard depth <= 25 else { return nil }
        budget -= 1
        guard budget > 0 else { return nil }
        switch value {
        case .object(let dict):
            if let renderer = dict["videoOwnerRenderer"], !renderer.isNull,
               let url = thumbnail(renderer["thumbnail"], avatar: true) {
                return url
            }
            for child in dict.values {
                if let found = walkOwnerAvatar(child, depth: depth + 1, budget: &budget) { return found }
            }
            return nil
        case .array(let items):
            for child in items {
                if let found = walkOwnerAvatar(child, depth: depth + 1, budget: &budget) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private static func microCategory(_ values: JSONValue...) -> String? {
        for value in values {
            if let category = value["category"].stringValue, !category.isEmpty { return category }
        }
        return nil
    }

    /// mimeType / CODECS codec token -> h264 / h265 / vp9 / av1.
    /// Testable without the network.
    static func codecName(_ raw: String) -> String {
        let lower = raw.lowercased()
        let first = lower.split(separator: ",").first.map(String.init) ?? lower
        if first.contains("av01") { return "av1" }
        if first.contains("vp09") || first.contains("vp9") { return "vp9" }
        if first.contains("hev1") || first.contains("hvc1") { return "h265" }
        if first.contains("avc1") || first.contains("h264") { return "h264" }
        return ""
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
