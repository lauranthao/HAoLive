// XiaohongshuSite.swift
// HAo Live — 小红书直播 adapter (anonymous, no login).
//
// 形态：本平台无浏览列表与服务端搜索，只能粘贴链接/输入 ID 直达
// （https://www.xiaohongshu.com/livestream/{roomId} 分享页、
// xhsdiscover://live_audience?room_id={roomId}、xhslink.com 短链，
// 或直接输数字 roomId）。categories() / recommendRooms() 一律返回 []，
// searchRooms() / searchAnchors() 只解析链接或 roomId 再调详情，
// 解析不出返回 []，不假装有搜索。弹幕：无（LiveSite 默认空实现）。
//
// 详情/取流（Pure Live lib/shared/platforms/xiaohongshu/
// xiaohongshu_api.dart + xiaohongshu_share.dart 为准）：
// GET https://www.xiaohongshu.com/livestream/{roomId} 分享页，解析
// 页内唯一的 `window.__INITIAL_STATE__=` 脚本（其中 liveStream）：
// roomData.roomInfo：roomId / status（2 = 在播，3 = 已结束）/
// roomTitle / roomCover / displayViewerCount / pullConfig
// （JSON 字符串：{h264: [{master_url, quality_type,
// quality_type_name}], h265: […]}）
// roomData.hostInfo：nickName / avatar
// liveStatus：'success' = 在播页，'end' = 已结束页
// monetizeType / joinLimitTypes：任一非 0 即受限（access != public
// 的播不了，跳过）。
// 档位 id 是 `{codec}:{quality}`（如 h264:HD），档位名是
// quality_type_name + codec。流地址只取 pullConfig 里的 master_url，
// 且只接受.xhscdn.com 域名下 /live/{roomId}.m3u8|.flv 的地址
// （Pure Live 的校验）；查询参数原样保留，不拼接。
// 分享页里的 nextRoomInfo / deeplink 预载 / replayInfo 不是本房间
// 的流来源，一律不取。
//
// 短链（xhslink.com）跟随跳转：URLSession 自动跟随到分享页，取落地页
// __INITIAL_STATE__ 里的 roomId 再走正常详情流程；跟不到返回 []。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class XiaohongshuSite: LiveSite, @unchecked Sendable {
let platform: LivePlatform = .xiaohongshu
private let http = HTTPClient.shared

private static let origin = "https://www.xiaohongshu.com"

/// Share-page request headers (Pure Live's XiaohongshuApi.headers:
/// Android mobile UA + Referer).
private static let pageHeaders: [String: String] = [
"Referer": "\(origin)/",
"User-Agent": "Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/87.0.4280.141 Mobile Safari/537.36",
]

// MARK: - Lists (none: link-only platform)

func categories() async throws -> [LiveCategory] { []}

func recommendRooms() async throws -> [LiveRoom] { []}

func categoryRooms(_ category: LiveCategory) async throws -> [LiveRoom] { []}

// MARK: - Search (link / roomId only)

func searchRooms(keyword: String) async throws -> [LiveRoom] {
try await search(keyword: keyword)
}

func searchAnchors(keyword: String) async throws -> [LiveRoom] {
try await search(keyword: keyword)
}

private func search(keyword: String) async throws -> [LiveRoom] {
guard let roomID = try? await resolveRoomID(keyword) else { return []}
guard let share = try? await fetchShare(roomID: roomID) else { return []}
// Not live, or restricted: not a playable room, do not list it.
guard share.isLive == true, share.access == .isPublic else { return []}
return [share.room]
}

// MARK: - Room detail

func roomDetail(roomID: String) async throws -> LiveRoom {
let resolved = try await resolveRoomID(roomID)
return try await fetchShare(roomID: resolved).room
}

// MARK: - Play URLs

func playURLs(room: LiveRoom) async throws -> [PlayStream] {
guard let roomID = try? await resolveRoomID(room.roomID) else { return []}
guard let share = try? await fetchShare(roomID: roomID),
share.isLive == true, share.access == .isPublic else { return []}
let headers = PlaybackHeaders.headers(platform: .xiaohongshu, roomID: roomID)
return share.streams.compactMap { info in
guard let url = URL(string: info.url) else { return nil}
return PlayStream(url: url, quality: info.qualityName, line: "主线路", headers: headers)
}
}

// MARK: - Share fetch

/// Parsed share-page snapshot (Pure Live's XiaohongshuShare).
struct Share {
var room: LiveRoom
var isLive: Bool?
var access: Access
var streams: [StreamInfo]
}

enum Access {
case isPublic
case restricted
case unknown
}

struct StreamInfo {
var url: String
var codec: String
var quality: String // "{codec}:{quality}" id, e.g. "h264:HD"
var qualityName: String { "\(label) · \(codec.uppercased())"}
var label: String
}

private func fetchShare(roomID: String) async throws -> Share {
guard Self.validateRoomID(roomID) != nil else {
throw LiveSiteError.roomNotFound(roomID)
}
let data = try await http.get("\(Self.origin)/livestream/\(roomID)", headers: Self.pageHeaders)
guard let html = String(data: data, encoding: .utf8) else {
throw LiveSiteError.invalidResponse
}
return try Self.parsePage(html, roomID: roomID)
}

/// Pure parser for the share page (Pure Live's
/// XiaohongshuShare.parsePage + parseState). Throws roomNotFound
/// when the page reports an error, invalidResponse on schema drift.
/// Testable without the network.
static func parsePage(_ page: String, roomID: String) throws -> Share {
guard validateRoomID(roomID) != nil else { throw LiveSiteError.roomNotFound(roomID)}
guard page.count <= 2 * 1024 * 1024 else { throw LiveSiteError.invalidResponse}
let marker = "window.__INITIAL_STATE__="
// Exactly one script may carry the marker (Pure Live's rule).
var occurrences = 0
var searchFrom = page.startIndex
while let range = page[searchFrom...].range(of: marker) {
occurrences += 1
searchFrom = range.upperBound
if occurrences > 1 { break}
}
guard occurrences == 1,
let markerRange = page.range(of: marker),
let openIndex = page[markerRange.upperBound...].firstIndex(of: "{"),
let rawObject = HaoText.extractJSONObject(page, from: openIndex) else {
throw LiveSiteError.invalidResponse
}
let source = hydrationJSON(rawObject)
guard let data = source.data(using: .utf8),
let root = JSONValue.parse(data) else {
throw LiveSiteError.invalidResponse
}
return try parseState(root["liveStream"], roomID: roomID)
}

/// Pure parser for the liveStream state object.
/// Testable without the network.
static func parseState(_ state: JSONValue, roomID: String) throws -> Share {
guard !state.isNull else { throw LiveSiteError.invalidResponse}
if state["pageStatus"].stringValue == "error" { throw LiveSiteError.roomNotFound(roomID)}
guard state["pageStatus"].stringValue == "success" else { throw LiveSiteError.invalidResponse}
let data = state["roomData"]
let roomInfo = data["roomInfo"]
let host = data["hostInfo"]
guard !roomInfo.isNull, !host.isNull else { throw LiveSiteError.invalidResponse}
if let responseID = roomInfo["roomId"].stringValue, responseID != roomID {
throw LiveSiteError.invalidResponse
}
let responseID = roomInfo["roomId"].stringValue
guard let status = roomInfo["status"].intValue, status >= 0 else {
throw LiveSiteError.invalidResponse
}
let liveStatus = state["liveStatus"].stringValue ?? ""
// Observed 2 = live, 3 = ended; other states stay unknown.
let isLive: Bool?
switch status {
case 2: isLive = true
case 3: isLive = false
default: isLive = nil
}
if (isLive == true && liveStatus != "success") || (isLive == false && liveStatus != "end") {
throw LiveSiteError.invalidResponse
}
if isLive == true, responseID == nil { throw LiveSiteError.invalidResponse}
let monetize = roomInfo["monetizeType"].intValue
let limits = roomInfo["joinLimitTypes"].arrayValue.compactMap(\.intValue)
let access: Access
if monetize == nil || roomInfo["joinLimitTypes"].isNull {
access = .unknown
} else if monetize != 0 || limits.contains(where: { $0 != 0}) {
access = .restricted
} else {
access = .isPublic
}
let streams: [StreamInfo]
if isLive == true, access == .isPublic {
streams = try Self.streams(fromPullConfig: roomInfo["pullConfig"], roomID: roomID)
} else {
streams = []
}
let title = roomInfo["roomTitle"].stringValue ?? ""
let nickname = host["nickName"].stringValue ?? ""
let room = LiveRoom(
id: "xiaohongshu-\(roomID)",
platform: .xiaohongshu,
roomID: roomID,
title: title,
anchorName: nickname,
anchorAvatarURL: Self.imageURL(host["avatar"].stringValue),
coverURL: Self.imageURL(roomInfo["roomCover"].stringValue),
categoryName: "小红书直播",
viewerCount: 0, // displayViewerCount is display text, not a count
isLive: isLive == true
)
return Share(room: room, isLive: isLive, access: access, streams: streams)
}

/// Pure parser for pullConfig (a JSON string):
/// {h264: [{master_url, quality_type, quality_type_name}],
/// h265: […]}. Only.xhscdn.com /live/{roomId}.m3u8|.flv URLs
/// are accepted (Pure Live's check). Testable without the network.
static func streams(fromPullConfig value: JSONValue, roomID: String) throws -> [StreamInfo] {
guard let text = value.stringValue, !text.isEmpty else { return []}
guard text.count <= 65_536,
let data = text.data(using: .utf8),
let config = JSONValue.parse(data) else {
throw LiveSiteError.invalidResponse
}
var out: [StreamInfo] = []
var seen: Set<String> = []
for codec in ["h264", "h265"] {
let rows = config[codec]
guard rows.isNull == false else { continue}
guard rows.arrayValue.count <= 32 else { throw LiveSiteError.invalidResponse}
for row in rows.arrayValue {
guard let url = row["master_url"].stringValue,
let quality = row["quality_type"].stringValue, !quality.isEmpty,
let label = row["quality_type_name"].stringValue, !label.isEmpty,
isValidStreamURL(url, roomID: roomID) else {
throw LiveSiteError.invalidResponse
}
let identity = "\(codec)|\(quality)|\(url)"
guard seen.insert(identity).inserted else { continue}
out.append(StreamInfo(url: url, codec: codec, quality: "\(codec):\(quality)", label: label))
}
}
return out
}

///.xhscdn.com host + /live/{roomId}.m3u8|.flv path, no user info,
/// no fragment, default port only. Testable without the network.
static func isValidStreamURL(_ raw: String, roomID: String) -> Bool {
guard let url = URL(string: raw),
(url.scheme == "http" || url.scheme == "https"),
let host = url.host?.lowercased(),
host.hasSuffix(".xhscdn.com"), host != ".xhscdn.com",
url.user == nil, url.fragment == nil,
url.port == nil || url.port == 443 || url.port == 80 else { return false}
return url.path == "/live/\(roomID).m3u8" || url.path == "/live/\(roomID).flv"
}

/// The hydration JSON carries bare `undefined` tokens for optional
/// config; only bare tokens outside strings become null (a global
/// replace would corrupt titles / URLs containing the word).
/// Port of XiaohongshuShare._hydrationJson. Testable without the network.
static func hydrationJSON(_ source: String) -> String {
var out = ""
out.reserveCapacity(source.count)
var quoted = false
var escaped = false
var index = source.startIndex
while index < source.endIndex {
let ch = source[index]
if quoted {
out.append(ch)
if escaped { escaped = false}
else if ch == "\\" { escaped = true}
else if ch == "\"" { quoted = false}
index = source.index(after: index)
} else if ch == "\"" {
quoted = true
out.append(ch)
index = source.index(after: index)
} else if source[index...].hasPrefix("undefined") {
out.append("null")
index = source.index(index, offsetBy: "undefined".count, limitedBy: source.endIndex) ?? source.endIndex
} else {
out.append(ch)
index = source.index(after: index)
}
}
return out
}

// MARK: - RoomId resolution (Pure Live's xiaohongshu_link.dart)

/// Bare numeric id, xhsdiscover deep link, /livestream/{id} (or
/// /livestream/dynpathXXXXXXXX/{id}, /hina/livestream/{id}/…),
/// xhslink.com short link (followed to the share page, whose
/// __INITIAL_STATE__ carries the roomId), or a share text that
/// embeds one of those URLs. Throws roomNotFound otherwise.
private func resolveRoomID(_ raw: String) async throws -> String {
let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
if let id = Self.parseLink(value) { return id}
// A share text mixes prose and a link: scan the embedded URLs.
for candidate in Self.extractURLs(value) {
if let id = Self.parseLink(candidate) { return id}
if let short = Self.shortURL(candidate) {
if let id = try? await resolveShortLink(short) { return id}
}
}
if let short = Self.shortURL(value) {
return try await resolveShortLink(short)
}
throw LiveSiteError.roomNotFound(raw)
}

/// Short link -> landing share page -> roomId from its state.
private func resolveShortLink(_ urlString: String) async throws -> String {
let data = try await http.get(urlString, headers: Self.pageHeaders)
guard let html = String(data: data, encoding: .utf8),
let id = Self.roomIDFromSharePage(html) else {
throw LiveSiteError.roomNotFound(urlString)
}
return id
}

/// roomId inside a share page's __INITIAL_STATE__ liveStream.
/// Testable without the network.
static func roomIDFromSharePage(_ html: String) -> String? {
let marker = "window.__INITIAL_STATE__="
guard let markerRange = html.range(of: marker),
let openIndex = html[markerRange.upperBound...].firstIndex(of: "{"),
let rawObject = HaoText.extractJSONObject(html, from: openIndex),
let data = hydrationJSON(rawObject).data(using: .utf8),
let root = JSONValue.parse(data) else { return nil}
return validateRoomID(root["liveStream"]["roomData"]["roomInfo"]["roomId"].stringValue ?? "")
}

/// Direct parse, no network: numeric id / deep link / web URL.
/// Testable without the network.
static func parseLink(_ raw: String) -> String? {
let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
if let id = validateRoomID(value) { return id}
if let id = deepLinkRoomID(value) { return id}
guard !value.contains("%"), !value.contains("\\"),
let url = URL(string: value),
(url.scheme == "https" || url.scheme == "http"),
url.user == nil,
(url.port == nil || url.port == 443 || url.port == 80),
url.host == "www.xiaohongshu.com" || url.host == "xiaohongshu.com" else { return nil}
let path = url.path
if let match = firstMatch(pattern: #"^/livestream/([1-9][0-9]{0,19})/?$"#, in: path) { return match}
if let match = firstMatch(pattern: #"^/livestream/dynpath[A-Za-z0-9]{8}/([1-9][0-9]{0,19})/?$"#, in: path) { return match}
if let match = firstMatch(pattern: #"^/hina/livestream/([1-9][0-9]{0,19})(?:/[A-Za-z0-9_-]{1,64})?/?$"#, in: path) { return match}
return nil
}

/// xhsdiscover://live_audience?room_id={id}. Testable without the network.
static func deepLinkRoomID(_ raw: String) -> String? {
let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
guard value.count <= 8192,
let url = URL(string: value),
url.scheme?.lowercased() == "xhsdiscover",
url.host?.lowercased() == "live_audience",
url.user == nil, url.port == nil, url.fragment == nil else { return nil}
guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
let items = comps.queryItems?.filter({ $0.name == "room_id"}),
items.count == 1,
let id = items[0].value else { return nil}
return validateRoomID(id)
}

/// xhslink.com short URL (single path segment, optional 1–4
/// letter prefix). Testable without the network.
static func shortURL(_ raw: String) -> String? {
let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
guard let url = URL(string: value),
(url.scheme == "https" || url.scheme == "http"),
url.host == "xhslink.com", url.user == nil, url.fragment == nil else { return nil}
guard url.path.range(of: #"^/(?:[A-Za-z]{1,4}/)?[A-Za-z0-9]{1,64}/?$"#, options: .regularExpression) != nil else { return nil}
return value
}

/// URLs embedded in a pasted share text. Testable without the network.
static func extractURLs(_ raw: String) -> [String] {
guard raw.count <= 8192 else { return []}
var out: [String] = []
var searchFrom = raw.startIndex
while let range = raw[searchFrom...].range(of: "http") {
let start = range.lowerBound
var end = start
while end < raw.endIndex,
!" \t\n，。；！？、《》「」『』（）·…".contains(raw[end]) {
end = raw.index(after: end)
}
var url = String(raw[start..<end])
while url.count > 1, url.hasSuffix(".") { url.removeLast()}
if !url.isEmpty { out.append(url)}
searchFrom = end
}
return out
}

/// First capture group of a one-group pattern, or nil.
private static func firstMatch(pattern: String, in text: String) -> String? {
guard let regex = try? NSRegularExpression(pattern: pattern),
let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
match.numberOfRanges >= 2,
let range = Range(match.range(at: 1), in: text) else { return nil}
return String(text[range])
}

/// `^[1-9][0-9]{0,19}$`. Testable without the network.
static func validateRoomID(_ raw: String?) -> String? {
guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
value.range(of: #"^[1-9][0-9]{0,19}$"#, options: .regularExpression) != nil else { return nil}
return value
}
}
