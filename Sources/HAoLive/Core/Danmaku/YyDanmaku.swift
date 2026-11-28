// YyDanmaku.swift
// HAo Live — YY danmaku over the H5 binary protocol.
// Port of Pure Live's yy_protocol.dart + yy_danmaku.dart (the
// protocol shape, re-implemented in Swift; no code copied).
// Endpoint: wss://h5-sinchl.yy.com/websocket?appid=yymwebh5
// &version=3.2.10&uuid={uuid} (URLSessionWebSocketTask; the
// reference's hand-rolled socket exists because Dart's WebSocket
// is case-sensitive about headers — iOS is not).
// Sequence: anonymous UDB login (778244) -> AP login (775684) ->
// channel join (2048258, routed through 513035) -> app-id
// subscription (538456) -> user-group subscriptions (537944).
// Chat arrives as app 31 / uri 3104600 (UCS-2 text), popularity as
// app 103 / uri 3139586. Heartbeat is the AP ping (794116) every 5s.
// The MAC-like device string in the login payloads is generated
// fresh per session (a random locally-administered MAC), not a
// copied constant. Anonymous, no login.
// NOTE: unverified live from this VM — the handshake was ported
// from the reference's documented sequence and unit-shaped pure
// functions only; a real room on a domestic network is still
// needed to confirm the server answers the join.

import Foundation

// MARK: - Little-endian binary reader

struct YyProtocolError: Error {
    var message: String
}

struct YyProtocolReader {
    private var bytes: [UInt8]
    /// Read cursor. Plain internal: the session repositions it when a
    /// chat block ends (readChat skips to chatEnd).
    var offset = 0
    var packetLength: Int?
    var uri: Int?
    var responseCode: Int?

    var bytesAvailable: Int { bytes.count - offset }

    init(_ bytes: [UInt8], hasHeader: Bool = false) throws {
        self.bytes = bytes
        if hasHeader {
            packetLength = try readUint32()
            uri = try readUint32()
            responseCode = try readUint16()
            guard let length = packetLength, length >= 10, length <= bytes.count else {
                throw YyProtocolError(message: "YY packet length out of range")
            }
        }
    }

    private mutating func require(_ length: Int) throws {
        guard length >= 0, offset + length <= bytes.count else {
            throw YyProtocolError(message: "YY packet truncated at \(offset): need \(length)")
        }
    }

    mutating func readUint8() throws -> Int {
        try require(1)
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    mutating func readUint16() throws -> Int {
        try require(2)
        let value = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func readUint32() throws -> Int {
        try require(4)
        var value = 0
        for i in 0..<4 { value |= Int(bytes[offset + i]) << (8 * i) }
        offset += 4
        return value
    }

    mutating func readUint64() throws -> UInt64 {
        let low = UInt64(try readUint32())
        let high = UInt64(try readUint32())
        return low | (high << 32)
    }

    mutating func readBytes(_ length: Int) throws -> [UInt8] {
        try require(length)
        let value = Array(bytes[offset..<offset + length])
        offset += length
        return value
    }

    mutating func readByteArray() throws -> [UInt8] {
        try readBytes(try readUint16())
    }

    mutating func readByteArray32() throws -> [UInt8] {
        try readBytes(try readUint32())
    }

    /// Latin-1 string (Dart's String.fromCharCodes on raw bytes).
    mutating func readString() throws -> String {
        let raw = try readByteArray()
        return String(bytes: raw, encoding: .isoLatin1) ?? ""
    }

    mutating func readUtf8String() throws -> String {
        let raw = try readByteArray()
        return String(decoding: raw, as: UTF8.self)
    }

    /// Length-prefixed UTF-16LE string.
    mutating func readUcs2String32() throws -> String {
        let raw = try readByteArray32()
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        var i = 0
        while i + 1 < raw.count {
            units.append(UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - Little-endian binary writer

struct YyProtocolWriter {
    private var buffer: [UInt8] = []
    private var uri: Int?

    init(uri: Int? = nil) {
        self.uri = uri
        if uri != nil {
            writeUint32(10)
            writeUint32(uri!)
            writeUint16(200)
        }
    }

    mutating func writeUint8(_ value: Int) {
        buffer.append(UInt8(value & 0xFF))
    }

    mutating func writeBool(_ value: Bool) {
        writeUint8(value ? 1 : 0)
    }

    mutating func writeUint16(_ value: Int) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func writeUint32(_ value: Int) {
        for i in 0..<4 { buffer.append(UInt8((value >> (8 * i)) & 0xFF)) }
    }

    mutating func writeUint64(_ value: UInt64) {
        writeUint32(Int(value & 0xFFFF_FFFF))
        writeUint32(Int((value >> 32) & 0xFFFF_FFFF))
    }

    mutating func writeBytes(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    mutating func writeByteArray(_ bytes: [UInt8]) {
        writeUint16(bytes.count)
        writeBytes(bytes)
    }

    mutating func writeByteArray32(_ bytes: [UInt8]) {
        writeUint32(bytes.count)
        writeBytes(bytes)
    }

    /// Latin-1 string (low byte of each UTF-16 unit, as in Dart's
    /// PMarshall.writeString).
    mutating func writeString(_ value: String) {
        writeByteArray(value.utf16.map { UInt8($0 & 0xFF) })
    }

    mutating func writeUtf8String(_ value: String) {
        writeByteArray(Array(value.utf8))
    }

    mutating func writeUcs2String32(_ value: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf16.count * 2)
        for unit in value.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8((unit >> 8) & 0xFF))
        }
        writeByteArray32(bytes)
    }

    func takeBytes() -> [UInt8] {
        var out = buffer
        if uri != nil {
            // Patch the length placeholder at offset 0.
            let length = out.count
            for i in 0..<4 { out[i] = UInt8((length >> (8 * i)) & 0xFF) }
        }
        return out
    }
}

// MARK: - Protocol session (state machine)

enum YyProtocolPhase: Int {
    case idle = 0, waitingUdb, waitingAp, waitingJoin, joined, failed
}

struct YyChatMessage {
    var userName: String
    var message: String
}

struct YyProtocolBatch {
    var outbound: [[UInt8]] = []
    var chats: [YyChatMessage] = []
    var becameReady = false
    var failure: String?
    var popularity: Int?
    var warnings: [String] = []
}

/// The protocol session. Only ever driven from one danmaku stream
/// task; the heartbeat task only calls buildHeartbeat(), which
/// reads phase/uid and writes nothing — hence @unchecked Sendable.
final class YyProtocolSession: @unchecked Sendable {
    // Protocol URIs (the YY H5 service's own numbering).
    private static let applicationID = 259
    private static let anonymousLoginRequestURI = 778244
    private static let anonymousLoginResponseURI = 778500
    private static let apLoginRequestURI = 775684
    private static let apLoginResponseURI = 775940
    private static let apPingRequestURI = 794116
    private static let apPongResponseURI = 794372
    private static let apRouterResponseURI = 512011
    private static let channelRouterRequestURI = 513035
    private static let joinChannelRequestURI = 2048258
    private static let joinChannelResponseURI = 2048514
    private static let joinUserGroupURI = 537944
    private static let userGroupMessageURI = 533080
    private static let bySidMessageURI = 28760
    private static let textChatURI = 3104600
    private static let audienceAppID = 103
    private static let popularityURI = 3139586
    private static let chatAppID = 31
    private static let subscribeAppIDsURI = 538456

    let topSid: Int
    let subSid: Int
    let uuid: String

    private(set) var phase: YyProtocolPhase = .idle
    private var uid: UInt64 = 0
    private var username = ""
    private var password = ""
    private var cookie: [UInt8] = []
    private var traceSequence = 0
    private let deviceID: String

    init(topSid: Int, subSid: Int, uuid: String) {
        self.topSid = topSid
        self.subSid = subSid
        self.uuid = uuid
        // Random locally-administered MAC per session (the reference
        // client's payloads carry a device id here; nothing about it
        // is an account credential).
        var bytes = (0..<6).map { _ in Int.random(in: 0..<256) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02
        self.deviceID = bytes.map { String(format: "%02X", $0) }.joined(separator: "-")
    }

    func beginHandshake() -> [UInt8] {
        phase = .waitingUdb
        uid = 0
        username = ""
        password = ""
        cookie = []
        traceSequence = 0
        return buildAnonymousLogin()
    }

    func buildHeartbeat() -> [UInt8]? {
        guard phase.rawValue >= YyProtocolPhase.waitingAp.rawValue, phase != .failed else { return nil }
        var writer = YyProtocolWriter(uri: Self.apPingRequestURI)
        writer.writeUint32(0)
        return writer.takeBytes()
    }

    func consume(_ message: [UInt8]) -> YyProtocolBatch {
        var batch = YyProtocolBatch()
        var offset = 0
        while offset < message.count {
            guard message.count - offset >= 10 else {
                batch.warnings.append("YY WebSocket 尾部数据不足 10 字节")
                break
            }
            let length = Int(message[offset])
                | (Int(message[offset + 1]) << 8)
                | (Int(message[offset + 2]) << 16)
                | (Int(message[offset + 3]) << 24)
            guard length >= 10, offset + length <= message.count else {
                batch.warnings.append("YY WebSocket 帧长度异常：\(length)/\(message.count - offset)")
                break
            }
            consumePacket(Array(message[offset..<offset + length]), batch: &batch)
            offset += length
        }
        return batch
    }

    private func consumePacket(_ packet: [UInt8], batch: inout YyProtocolBatch) {
        do {
            var reader = try YyProtocolReader(packet, hasHeader: true)
            switch reader.uri {
            case Self.anonymousLoginResponseURI:
                consumeAnonymousLogin(&reader, batch: &batch)
            case Self.apLoginResponseURI:
                consumeApLogin(&reader, batch: &batch)
            case Self.apRouterResponseURI:
                consumeRouter(&reader, batch: &batch)
            case Self.userGroupMessageURI:
                consumeUserGroup(&reader, batch: &batch)
            case Self.bySidMessageURI:
                consumeBySid(&reader, batch: &batch)
            case Self.apPongResponseURI:
                break
            default:
                break
            }
        } catch {
            if phase == .waitingUdb || phase == .waitingAp || phase == .waitingJoin {
                fail(&batch, "YY 弹幕协议握手数据异常：\(error)")
            } else {
                batch.warnings.append("YY 弹幕消息解析异常：\(error)")
            }
        }
    }

    private func consumeAnonymousLogin(_ reader: inout YyProtocolReader, batch: inout YyProtocolBatch) {
        guard phase == .waitingUdb else { return }
        do {
            _ = try reader.readString()
            let envelopeCode = try reader.readUint32()
            let realURI = try reader.readUint32()
            let payload = try reader.readByteArray32()
            guard realURI == 20078 else {
                fail(&batch, "YY 匿名登录返回了未知协议：\(realURI)")
                return
            }
            var payloadReader = try YyProtocolReader(payload)
            _ = try payloadReader.readString()
            let resultCode = try payloadReader.readUint32()
            let uid32 = try payloadReader.readUint32()
            _ = try payloadReader.readUint32() // yyid
            username = try payloadReader.readString()
            password = try payloadReader.readString()
            cookie = try payloadReader.readByteArray()
            _ = try payloadReader.readByteArray() // ticket
            _ = try payloadReader.readString()
            _ = try payloadReader.readString()
            uid = payloadReader.bytesAvailable >= 8 ? try payloadReader.readUint64() : UInt64(uid32)
            guard isSuccess(envelopeCode), isSuccess(resultCode), uid != 0 else {
                fail(&batch, "YY 匿名登录失败：\(envelopeCode)/\(resultCode)")
                return
            }
            phase = .waitingAp
            batch.outbound.append(buildApLogin())
        } catch {
            fail(&batch, "YY 匿名登录解析失败：\(error)")
        }
    }

    private func consumeApLogin(_ reader: inout YyProtocolReader, batch: inout YyProtocolBatch) {
        guard phase == .waitingAp else { return }
        do {
            _ = try reader.readUint32() // appid
            let resultCode = try reader.readUint32()
            _ = try reader.readString() // context: appid:userType
            guard resultCode == 200 else {
                fail(&batch, "YY AP 登录失败：\(resultCode)")
                return
            }
            phase = .waitingJoin
            batch.outbound.append(buildJoinChannel())
            batch.outbound.append(buildAppIDSubscription())
        } catch {
            fail(&batch, "YY AP 登录解析失败：\(error)")
        }
    }

    private func consumeRouter(_ reader: inout YyProtocolReader, batch: inout YyProtocolBatch) {
        do {
            _ = try reader.readString()
            let realURI = try reader.readUint32()
            let responseCode = try reader.readUint16()
            let payload = try reader.readByteArray32()
            if responseCode != 0 && responseCode != 200 {
                if realURI == Self.joinChannelResponseURI {
                    fail(&batch, "YY 加入频道路由失败：\(responseCode)")
                }
                return
            }
            if realURI == Self.joinChannelResponseURI {
                var payloadReader = try YyProtocolReader(payload)
                consumeJoinResponse(&payloadReader, batch: &batch)
            } else if realURI == Self.userGroupMessageURI {
                var payloadReader = try YyProtocolReader(payload)
                consumeUserGroup(&payloadReader, batch: &batch)
            }
        } catch {
            batch.warnings.append("YY 路由消息解析异常：\(error)")
        }
    }

    private func consumeJoinResponse(_ reader: inout YyProtocolReader, batch: inout YyProtocolBatch) {
        guard phase == .waitingJoin else { return }
        do {
            let joinedTopSid = try reader.readUint32()
            _ = try reader.readUint32() // uid32
            let joinedSubSid = try reader.readUint32()
            _ = try reader.readUint32() // asid
            _ = try reader.readUint32() // login timestamp
            let loginStatus = try reader.readUint8()
            let errorInfo = try reader.readUtf8String()
            guard loginStatus == 4, joinedTopSid == topSid, joinedSubSid == subSid else {
                fail(&batch, "YY 加入频道失败：\(loginStatus)\(errorInfo.isEmpty ? "" : "，\(errorInfo)")")
                return
            }
            phase = .joined
            batch.outbound.append(buildUserGroupSubscription(includeChannelGroups: true))
            batch.outbound.append(buildUserGroupSubscription(includeChannelGroups: false))
            batch.becameReady = true
        } catch {
            fail(&batch, "YY 加入频道解析失败：\(error)")
        }
    }

    private func consumeUserGroup(_ reader: inout YyProtocolReader, batch: inout YyProtocolBatch) {
        do {
            _ = try reader.readUint64() // group type
            _ = try reader.readUint64() // group id
            let appID = try reader.readUint32()
            let message = try reader.readByteArray32()
            consumeServiceMessage(appID: appID, message: message, batch: &batch)
        } catch {
            batch.warnings.append("YY 用户组消息解析异常：\(error)")
        }
    }

    private func consumeBySid(_ reader: inout YyProtocolReader, batch: inout YyProtocolBatch) {
        do {
            let appID = try reader.readUint16()
            _ = try reader.readUint32() // topSid envelope field
            let message = try reader.readByteArray()
            consumeServiceMessage(appID: appID, message: message, batch: &batch)
        } catch {
            batch.warnings.append("YY BySid 消息解析异常：\(error)")
        }
    }

    private func consumeServiceMessage(appID: Int, message: [UInt8], batch: inout YyProtocolBatch) {
        guard phase == .joined,
              (appID == Self.chatAppID || appID == Self.audienceAppID) else { return }
        guard appID != Self.audienceAppID || message.count >= 10 else { return }
        do {
            var reader = try YyProtocolReader(message, hasHeader: true)
            if appID == Self.chatAppID {
                guard reader.uri == Self.textChatURI else { return }
                if let chat = try readChat(&reader) {
                    batch.chats.append(chat)
                }
            } else {
                guard reader.uri == Self.popularityURI else { return }
                if let heat = try readPopularity(&reader) {
                    batch.popularity = heat
                }
            }
        } catch {
            batch.warnings.append(appID == Self.chatAppID ? "YY 聊天消息格式异常：\(error)" : "YY 人气消息格式异常：\(error)")
        }
    }

    private func readPopularity(_ reader: inout YyProtocolReader) throws -> Int? {
        let heat = try reader.readUint32()
        _ = try reader.readUint32()
        guard try reader.readUint32() == topSid else { return nil }
        return heat
    }

    private func readChat(_ reader: inout YyProtocolReader) throws -> YyChatMessage? {
        _ = try reader.readUint32() // sender uid32
        let messageTopSid = try reader.readUint32()
        let messageSubSid = try reader.readUint32()
        guard messageTopSid == topSid, messageSubSid == subSid else { return nil }
        let chatLength = try reader.readUint16()
        let chatEnd = reader.offset + chatLength
        _ = try reader.readUint32() // font effects
        _ = try reader.readUcs2String32() // font name
        _ = try reader.readUint32() // color
        _ = try reader.readUint32() // font height
        let message = try reader.readUcs2String32().trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try reader.readUint32() // screen mode
        guard reader.offset <= chatEnd else {
            throw YyProtocolError(message: "YY 聊天正文长度越界")
        }
        reader.offset = chatEnd // skip to the end of the chat block
        _ = try reader.readString()
        _ = try reader.readString()
        var userName = ""
        if reader.bytesAvailable > 0 {
            userName = try reader.readUtf8String().trimmingCharacters(in: .whitespacesAndNewlines)
            let extraCount = try reader.readUint32()
            for _ in 0..<extraCount {
                _ = try reader.readUint16()
                _ = try reader.readUtf8String()
            }
        }
        guard !message.isEmpty else { return nil }
        return YyChatMessage(userName: userName.isEmpty ? "YY用户" : userName, message: message)
    }

    // MARK: - Packet builders

    private func buildAnonymousLogin() -> [UInt8] {
        var payload = YyProtocolWriter()
        payload.writeString("")
        payload.writeUint32(0)
        payload.writeString(deviceID)
        payload.writeString(deviceID)
        payload.writeUint32(0)
        payload.writeString("yymwebh5")
        var writer = YyProtocolWriter(uri: Self.anonymousLoginRequestURI)
        writer.writeString("")
        writer.writeUint32(19822)
        writer.writeByteArray32(payload.takeBytes())
        return writer.takeBytes()
    }

    private func buildApLogin() -> [UInt8] {
        var auth = YyProtocolWriter()
        auth.writeString(username)
        auth.writeString(password)
        auth.writeUint32(2)
        auth.writeUint32(0)
        auth.writeUint32(0)
        auth.writeString("yytianlaitv")
        auth.writeString(deviceID)
        auth.writeString("yymwebn_yymwebh5")
        auth.writeUint32(0)
        auth.writeUint32(0)
        auth.writeUint32(0)
        auth.writeUint32(0)
        auth.writeString(uuid)
        var writer = YyProtocolWriter(uri: Self.apLoginRequestURI)
        writer.writeByteArray32(auth.takeBytes())
        writer.writeUint32(Self.applicationID)
        writer.writeUint64(uid)
        writer.writeBool(false)
        writer.writeByteArray([])
        writer.writeByteArray(cookie)
        writer.writeString("259:0")
        writer.writeString("")
        writer.writeString("")
        writer.writeString("")
        writer.writeUint8(0)
        writer.writeUint32(0)
        writer.writeUint32(0)
        writer.writeUint32(0xFFFF_FFFF)
        writer.writeString("")
        writer.writeUint32(1)
        writer.writeString("BCIFVer")
        writer.writeString("V2")
        return writer.takeBytes()
    }

    private func buildAppIDSubscription() -> [UInt8] {
        let appIDs = [31, 101, 102, 103, 17]
        var writer = YyProtocolWriter(uri: Self.subscribeAppIDsURI)
        writer.writeUint64(uid)
        writer.writeUint32(appIDs.count)
        for appID in appIDs { writer.writeUint32(appID) }
        return writer.takeBytes()
    }

    private func buildJoinChannel() -> [UInt8] {
        var payload = YyProtocolWriter()
        payload.writeUint32(Int(uid & 0xFFFF_FFFF))
        payload.writeUint32(topSid)
        payload.writeUint32(subSid)
        payload.writeUint32(2)
        payload.writeUint32(2)
        payload.writeString("0")
        payload.writeUint32(3)
        payload.writeString("1")
        payload.writeUint64(uid)
        return buildChannelRouter(
            realURI: Self.joinChannelRequestURI,
            serviceName: "channelAuther",
            payload: payload.takeBytes()
        )
    }

    private func buildChannelRouter(realURI: Int, serviceName: String, payload: [UInt8]) -> [UInt8] {
        var topSidWriter = YyProtocolWriter()
        topSidWriter.writeUint32(topSid)
        let traceID = "F\(uid)_yymwebh5_\(Int.random(in: 0..<100000))_\(traceSequence)"
        traceSequence += 1
        let extensions: [(key: Int, value: Any)] = [
            (key: 1, value: topSidWriter.takeBytes()),
            (key: 103, value: traceID),
        ]
        let headers = buildRouterHeaders(realURI: realURI, serviceName: serviceName, extensions: extensions)
        var writer = YyProtocolWriter(uri: Self.channelRouterRequestURI)
        writer.writeString("")
        writer.writeUint32(realURI)
        writer.writeUint16(0)
        writer.writeByteArray32(payload)
        writer.writeByteArray32(headers)
        return writer.takeBytes()
    }

    private func buildRouterHeaders(realURI: Int, serviceName: String, extensions: [(key: Int, value: Any)]) -> [UInt8] {
        var writer = YyProtocolWriter()
        writer.writeUint32(0x01000008)
        writer.writeUint32(realURI)
        writer.writeUint32(0x02000010)
        writer.writeUint32(Self.applicationID)
        writer.writeUint64(uid)
        writer.writeUint32(0x0400000C)
        writer.writeUint32(0)
        writer.writeUint32(0)
        writer.writeUint32(0x05000008)
        writer.writeUint32(0)
        let routeSectionLength = 22 + serviceName.count
        writer.writeUint32(0x06000000 | routeSectionLength)
        writer.writeUint32(0)
        writer.writeUint16(0)
        writer.writeUint32(0)
        writer.writeString(serviceName)
        writer.writeUint32(0)
        writer.writeString("")
        var extensionSectionLength = 8
        for ext in extensions {
            let valueLength: Int
            if let bytes = ext.value as? [UInt8] { valueLength = bytes.count }
            else if let string = ext.value as? String { valueLength = string.count }
            else { valueLength = 0 }
            extensionSectionLength += 4 + 2 + valueLength
        }
        writer.writeUint32(0x07000000 | extensionSectionLength)
        writer.writeUint32(extensions.count)
        for ext in extensions {
            writer.writeUint32(ext.key)
            if let bytes = ext.value as? [UInt8] {
                writer.writeByteArray(bytes)
            } else if let string = ext.value as? String {
                writer.writeString(string)
            }
        }
        writer.writeUint32(0x08000006)
        writer.writeString("")
        writer.writeUint32(0xFF787878)
        return writer.takeBytes()
    }

    private func buildUserGroupSubscription(includeChannelGroups: Bool) -> [UInt8] {
        let groups: [[Int]] = includeChannelGroups ? [
            [1, 0, topSid, 0],
            [2, 0, subSid, 0],
            [1024, 259, subSid, topSid],
            [768, 259, 0, topSid],
            [256, 259, 0, topSid],
            [256, 259, subSid, topSid],
        ] : [
            [1, 0, topSid, 0],
            [2, 0, subSid, 0],
        ]
        var writer = YyProtocolWriter(uri: Self.joinUserGroupURI)
        writer.writeUint64(uid)
        writer.writeUint32(groups.count)
        for group in groups {
            for value in group { writer.writeUint32(value) }
        }
        writer.writeString("")
        return writer.takeBytes()
    }

    private func fail(_ batch: inout YyProtocolBatch, _ message: String) {
        phase = .failed
        if batch.failure == nil { batch.failure = message }
    }

    private func isSuccess(_ code: Int) -> Bool {
        code == 0 || code == 200
    }
}

// MARK: - Live stream

/// One-shot flag shared between the stream task and its handshake
/// timeout task (same pattern as DanmakuSocket's ResumedFlag).
final class JoinedBox: @unchecked Sendable {
    var value = false
}

enum YyDanmaku {
    private static let wsBase = "wss://h5-sinchl.yy.com/websocket"
    private static let protocolVersion = "3.2.10"
    private static let heartbeatIntervalSeconds: UInt64 = 5
    private static let handshakeTimeoutSeconds: UInt64 = 15

    static func webSocketURL(uuid: String) -> URL? {
        URL(string: "\(wsBase)?appid=yymwebh5&version=\(protocolVersion)&uuid=\(uuid)")
    }

    /// Resolve (topSid, subSid) for a room id via liveInfoDetail.
    /// Falls back to the numeric room id for both when the detail
    /// call fails.
    static func channelIDs(roomID: String) async -> (topSid: Int, subSid: Int) {
        let sid = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? await HTTPClient.shared.getJSON(
            "https://www.yy.com/api/liveInfoDetail/\(sid)/\(sid)/0",
            headers: [
                "Accept": "*/*",
                "Origin": "https://www.yy.com",
                "Referer": "https://www.yy.com/",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            ]),
           json["resultCode"].intValue == 0,
           let top = json["data"]["sid"].intValue, top > 0 {
            return (topSid: top, subSid: json["data"]["ssid"].intValue ?? top)
        }
        if let numeric = Int(sid), numeric > 0 {
            return (topSid: numeric, subSid: numeric)
        }
        return (topSid: 0, subSid: 0)
    }

#if !os(Linux)
    /// Live stream of danmaku for a room (roomID is the numeric sid).
    /// Ends quietly when the channel ids cannot be resolved, the
    /// handshake times out, or the socket drops.
    static func stream(roomID: String) -> AsyncStream<DanmakuItem> {
        AsyncStream { continuation in
            let task = Task {
                let ids = await channelIDs(roomID: roomID)
                guard ids.topSid > 0,
                      let url = webSocketURL(uuid: UUID().uuidString.lowercased()) else {
                    continuation.finish()
                    return
                }
                let session = YyProtocolSession(topSid: ids.topSid, subSid: ids.subSid, uuid: UUID().uuidString.lowercased())
                let socket: any DanmakuSocket = WebSocketTransport()
                do {
                    try await socket.connect(url: url, headers: [
                        "Origin": "https://www.yy.com",
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
                    ])
                    try await socket.send(Data(session.beginHandshake()))
                    let joinedBox = JoinedBox()
                    let timeout = Task {
                        try? await Task.sleep(for: .seconds(Int(handshakeTimeoutSeconds)))
                        if !joinedBox.value { socket.close() }
                    }
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(Int(heartbeatIntervalSeconds)))
                            if let packet = session.buildHeartbeat() {
                                try? await socket.send(Data(packet))
                            }
                        }
                    }
                    defer {
                        timeout.cancel()
                        heartbeat.cancel()
                    }
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        let batch = session.consume([UInt8](data))
                        for packet in batch.outbound {
                            try await socket.send(Data(packet))
                        }
                        if batch.becameReady { joinedBox.value = true }
                        for chat in batch.chats {
                            continuation.yield(DanmakuItem(roomID: roomID, user: chat.userName, text: chat.message))
                        }
                        if batch.failure != nil { break }
                    }
                } catch {
                    // Connection dropped: the stream simply ends.
                }
                socket.close()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif
}
