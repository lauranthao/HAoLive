// LiveRecorder.swift
// HAo Live — records the same HLS stream the player is playing by
// downloading its media segments to disk and writing a local .m3u8
// index, so AVPlayer can play the recording back offline.
//
// Why HLS segments, not ffmpeg (Pure Live's way): the app has no
// ffmpeg and AVPlayer only plays HLS. The function matches Pure Live's
// recorder — record button on the room page, tasks with live status,
// a recordings center with play + delete — the mechanism is HAo's own.
//
// Design:
// - One recording at a time. The recorder is owned by the app, not by
//   the room page, so leaving the room (or switching tabs) does not
//   kill a recording; it runs until the user stops it, the stream ends,
//   or the playlist fails 5 times in a row.
// - The download loop runs off the main actor (Task.detached); only
//   progress and finalization touch @MainActor state. Playback is never
//   touched: the recorder downloads the stream URL directly, in parallel
//   with AVPlayer, and never pauses or replaces the player item.
// - A failed segment download is skipped, never retried inline, and the
//   recording is marked as having a gap. A failed playlist fetch retries
//   with backoff; 5 consecutive failures end the recording (what was
//   saved stays playable).
// - iOS suspends the app in the background, so recording pauses there.
//   On return the loop re-fetches the playlist and continues from the
//   live edge; segments that slid out of the window while suspended are
//   missed and the recording is marked as having a gap. This is a
//   platform limit, not a bug: there is no background download session
//   for a live edge that moves on without us.
// - Encrypted streams (#EXT-X-KEY with METHOD != NONE) are refused
//   up front instead of saving segments that cannot play back offline.

import Combine
import Foundation

@MainActor
final class LiveRecorder: ObservableObject {
    /// Live state of the recording in progress, if any.
    struct ActiveSession {
        var room: LiveRoom
        var stream: PlayStream
        var startedAt: Date
        var segmentsSaved: Int
        var bytesSaved: Int64
        var hasGap: Bool
        var skippedSegments: Int
    }

    enum StartResult {
        case started
        case alreadyRecording
        /// Another room is being recorded; the value is its title.
        case busy(String)
        case failed(String)
    }

    @Published private(set) var active: ActiveSession?
    @Published private(set) var lastError: String?

    let store: RecordingStore

    var isRecording: Bool { active != nil }

    func isRecording(room: LiveRoom) -> Bool {
        active?.room.id == room.id
    }

    init(store: RecordingStore = RecordingStore()) {
        self.store = store
    }

    // MARK: - Start / stop

    func start(room: LiveRoom, stream: PlayStream) -> StartResult {
        if let active {
            return active.room.id == room.id ? .alreadyRecording : .busy(active.room.title)
        }
        lastError = nil

        let id = UUID().uuidString
        let startedAt = Date()
        let folderName = Self.folderName(platform: room.platform, roomID: room.roomID, date: startedAt)
        let folder = store.directory.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed("无法创建录制文件夹")
        }

        store.add(Recording(
            id: id,
            roomID: room.roomID,
            platform: room.platform,
            title: room.title,
            anchorName: room.anchorName,
            quality: stream.quality,
            line: stream.line,
            folderName: folderName,
            startedAt: startedAt,
            endedAt: nil,
            durationSeconds: 0,
            fileSizeBytes: 0,
            segmentCount: 0,
            hasGap: false,
            status: .recording,
            errorMessage: nil
        ))

        active = ActiveSession(
            room: room, stream: stream, startedAt: startedAt,
            segmentsSaved: 0, bytesSaved: 0, hasGap: false, skippedSegments: 0
        )
        let params = LoopParams(playlistURL: stream.url, folder: folder, recordingID: id, startedAt: startedAt)
        runTask = Task.detached { [weak self] in
            guard let self else { return }
            let outcome = await self.runLoop(params: params)
            await self.finishRecording(outcome)
        }
        return .started
    }

    /// Stop the recording and wait for the index to be finalized.
    func stop() async {
        guard let task = runTask else { return }
        task.cancel()
        await task.value
        runTask = nil
    }

    // MARK: - Progress

    private func applyProgress(segments: Int, bytes: Int64, hasGap: Bool, skipped: Int) {
        guard var session = active else { return }
        session.segmentsSaved = segments
        session.bytesSaved = bytes
        session.hasGap = hasGap
        session.skippedSegments = skipped
        active = session
    }

    // MARK: - The download loop (off the main actor)

    private struct LoopParams: Sendable {
        var playlistURL: URL
        var folder: URL
        var recordingID: String
        var startedAt: Date
    }

    private struct SavedSegment: Sendable {
        var sequence: Int
        var fileName: String
        var duration: Double
        var discontinuity: Bool
    }

    private enum LoopOutcome: Sendable {
        case stoppedByUser
        case streamEnded
        case failed(String)
    }

    private struct FinishData: Sendable {
        var recordingID: String
        var folder: URL
        var startedAt: Date
        var outcome: LoopOutcome
        var saved: [SavedSegment]
        var mapFileName: String?
        var targetDuration: Double
        var hasGap: Bool
        var skipped: Int
    }

    private var runTask: Task<Void, Never>?

    /// Downloads segments until the user stops, the stream ends, or the
    /// playlist fails repeatedly. Never throws: every exit funnels into
    /// one FinishData for `finishRecording`.
    private nonisolated func runLoop(params: LoopParams) async -> FinishData {
        var mediaURL = params.playlistURL
        var lastSequence = -1
        var firstSequence = 0
        var saved: [SavedSegment] = []
        var targetDuration = 6.0
        var mapFileName: String?
        var mapDownloaded = false
        var hasGap = false
        var skipped = 0
        var bytesSaved: Int64 = 0
        var consecutiveFailures = 0
        var outcome: LoopOutcome = .stoppedByUser

        func fileName(for segment: HLSMediaSegment) -> String {
            let ext = segment.uri.pathExtension.isEmpty ? "ts" : segment.uri.pathExtension
            return "seg-\(segment.sequence).\(ext)"
        }

        func writeIndex(ended: Bool) {
            let entries = saved.map {
                LocalHLSIndex.Entry(fileName: $0.fileName, duration: $0.duration, discontinuity: $0.discontinuity)
            }
            let text = LocalHLSIndex.text(
                firstSequence: firstSequence,
                targetDuration: Int(ceil(targetDuration)),
                version: 3,
                mapFileName: mapFileName,
                entries: entries,
                ended: ended
            )
            try? text.write(to: params.folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        }

        // Resolve a master playlist to its best variant before polling.
        if let outcome = await resolveVariant(mediaURL: &mediaURL, params: params) {
            return FinishData(recordingID: params.recordingID, folder: params.folder, startedAt: params.startedAt,
                              outcome: outcome, saved: saved, mapFileName: nil,
                              targetDuration: targetDuration, hasGap: hasGap, skipped: skipped)
        }

        while !Task.isCancelled {
            do {
                let text = try await HTTPClient.shared.get(mediaURL.absoluteString)
                consecutiveFailures = 0
                guard let playlist = HLSPlaylistParser.parse(text, baseURL: mediaURL) else {
                    throw LiveSiteError.invalidResponse
                }
                switch playlist {
                case .master(let variants):
                    // The "media" URL turned out to be another master list.
                    guard let best = HLSPlaylistParser.bestVariant(variants) else {
                        outcome = .failed("无法解析播放列表")
                        return FinishData(recordingID: params.recordingID, folder: params.folder, startedAt: params.startedAt,
                                          outcome: outcome, saved: saved, mapFileName: mapFileName,
                                          targetDuration: targetDuration, hasGap: hasGap, skipped: skipped)
                    }
                    mediaURL = best.uri
                    continue
                case .media(let media):
                    if media.isEncrypted {
                        outcome = .failed("该线路为加密流，暂不支持录制")
                        return FinishData(recordingID: params.recordingID, folder: params.folder, startedAt: params.startedAt,
                                          outcome: outcome, saved: saved, mapFileName: mapFileName,
                                          targetDuration: targetDuration, hasGap: hasGap, skipped: skipped)
                    }
                    if media.targetDuration > 0 { targetDuration = media.targetDuration }

                    if let mapURI = media.mapURI, !mapDownloaded {
                        if let data = try? await HTTPClient.shared.get(mapURI.absoluteString) {
                            let ext = mapURI.pathExtension.isEmpty ? "mp4" : mapURI.pathExtension
                            mapFileName = "init.\(ext)"
                            try? data.write(to: params.folder.appendingPathComponent(mapFileName!))
                            bytesSaved += Int64(data.count)
                            mapDownloaded = true
                        }
                    }

                    if lastSequence < 0 {
                        firstSequence = media.segments.first?.sequence ?? media.mediaSequence
                    } else if media.mediaSequence > lastSequence + 1 {
                        // The live edge moved past segments we never saw
                        // (background suspension, or a slow poll): gap.
                        hasGap = true
                    }
                    for segment in media.segments where segment.sequence > lastSequence {
                        if Task.isCancelled { break }
                        let name = fileName(for: segment)
                        do {
                            let data = try await HTTPClient.shared.get(segment.uri.absoluteString)
                            try data.write(to: params.folder.appendingPathComponent(name))
                            bytesSaved += Int64(data.count)
                            saved.append(SavedSegment(sequence: segment.sequence, fileName: name,
                                                      duration: segment.duration, discontinuity: segment.discontinuity))
                        } catch is CancellationError {
                            break
                        } catch {
                            // Skip the segment, keep going, mark the gap.
                            skipped += 1
                            hasGap = true
                        }
                        lastSequence = max(lastSequence, segment.sequence)
                    }
                    writeIndex(ended: false)
                    await self.applyProgress(segments: saved.count, bytes: bytesSaved, hasGap: hasGap, skipped: skipped)
                    if media.isEndList {
                        outcome = .streamEnded
                        return FinishData(recordingID: params.recordingID, folder: params.folder, startedAt: params.startedAt,
                                          outcome: outcome, saved: saved, mapFileName: mapFileName,
                                          targetDuration: targetDuration, hasGap: hasGap, skipped: skipped)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 5 {
                    outcome = .failed("连续 5 次拉取播放列表失败，录制已停止")
                    return FinishData(recordingID: params.recordingID, folder: params.folder, startedAt: params.startedAt,
                                      outcome: outcome, saved: saved, mapFileName: mapFileName,
                                      targetDuration: targetDuration, hasGap: hasGap, skipped: skipped)
                }
            }

            let intervalMs = Int64(min(max(targetDuration / 2, 2), 10) * 1000)
            do {
                try await Task.sleep(for: .milliseconds(intervalMs))
            } catch {
                break
            }
        }

        return FinishData(recordingID: params.recordingID, folder: params.folder, startedAt: params.startedAt,
                          outcome: outcome, saved: saved, mapFileName: mapFileName,
                          targetDuration: targetDuration, hasGap: hasGap, skipped: skipped)
    }

    /// If the stream URL is a master playlist, follow its best variant.
    /// Returns a failure outcome when it cannot be resolved.
    private nonisolated func resolveVariant(mediaURL: inout URL, params: LoopParams) async -> LoopOutcome? {
        do {
            let text = try await HTTPClient.shared.get(mediaURL.absoluteString)
            guard let playlist = HLSPlaylistParser.parse(text, baseURL: mediaURL) else {
                return .failed("无法解析播放列表")
            }
            if case .master(let variants) = playlist {
                guard let best = HLSPlaylistParser.bestVariant(variants) else {
                    return .failed("无法解析播放列表")
                }
                mediaURL = best.uri
            }
            return nil
        } catch is CancellationError {
            return .stoppedByUser
        } catch {
            return .failed("拉取播放列表失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Finalization (main actor)

    private func finishRecording(_ data: FinishData) {
        runTask = nil
        active = nil

        guard var recording = store.recording(id: data.recordingID) else { return }

        if data.saved.isEmpty {
            // Nothing was captured: leave no empty folder, no list entry.
            try? FileManager.default.removeItem(at: data.folder)
            store.remove(recording)
            let message: String
            switch data.outcome {
            case .failed(let text): message = text
            case .streamEnded: message = "直播已结束，未录到内容"
            case .stoppedByUser: message = "未录到内容"
            }
            lastError = message
            return
        }

        // Final index with ENDLIST, so the recording plays back offline.
        let entries = data.saved.map {
            LocalHLSIndex.Entry(fileName: $0.fileName, duration: $0.duration, discontinuity: $0.discontinuity)
        }
        let text = LocalHLSIndex.text(
            firstSequence: data.saved.first?.sequence ?? 0,
            targetDuration: Int(ceil(data.targetDuration)),
            version: 3,
            mapFileName: data.mapFileName,
            entries: entries,
            ended: true
        )
        try? text.write(to: data.folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)

        recording.endedAt = Date()
        recording.durationSeconds = data.saved.reduce(0) { $0 + $1.duration }
        recording.fileSizeBytes = RecordingStore.folderSize(data.folder)
        recording.segmentCount = data.saved.count
        recording.hasGap = data.hasGap
        switch data.outcome {
        case .stoppedByUser, .streamEnded:
            recording.status = .completed
            recording.errorMessage = data.outcome == .streamEnded ? "直播已结束" : nil
        case .failed(let message):
            recording.status = .failed
            recording.errorMessage = message
            lastError = message
        }
        store.update(recording)
    }

    // MARK: - Helpers

    private static func folderName(platform: LivePlatform, roomID: String, date: Date) -> String {
        let safeRoom = roomID
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(platform.rawValue)-\(safeRoom)-\(formatter.string(from: date))"
    }
}
