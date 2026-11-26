// RecordingStore.swift
// HAo Live — finished (and interrupted) recordings on disk.
// One folder per recording under Documents/recordings/:
//   <platform>-<roomID>-<yyyyMMdd-HHmmss>/index.m3u8 + segments
// Metadata lives in recordings.json next to the folders. On launch the
// store rescans the disk, so a recording interrupted by a crash or by
// the app being killed still shows up (as 未完成) instead of vanishing,
// and folders deleted outside the app disappear from the list.

import Combine
import Foundation

/// One recording on disk. The folder holds index.m3u8 plus the media
/// segments; the metadata here is only the list view (title, times,
/// size, duration) and the folder name.
struct Recording: Identifiable, Hashable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Actively recording right now.
        case recording
        /// Stopped by the user, or the stream ended: complete index.
        case completed
        /// Stopped by an error after some segments were saved: playable,
        /// but marked so the user knows it may cut off early.
        case failed
        /// The app died or was killed mid-recording: index exists and
        /// plays, but the end is missing.
        case incomplete
    }

    var id: String
    var roomID: String
    var platform: LivePlatform
    var title: String
    var anchorName: String
    var quality: String
    var line: String
    var folderName: String
    var startedAt: Date
    var endedAt: Date?
    /// Sum of saved segment durations. Unknown (0) for recordings
    /// recovered from disk without metadata.
    var durationSeconds: Double
    var fileSizeBytes: Int64
    var segmentCount: Int
    var hasGap: Bool
    var status: Status
    var errorMessage: String?

    var displayDuration: String {
        guard durationSeconds > 0 else { return "时长未知" }
        return RecordingFormatters.duration(durationSeconds)
    }

    var displaySize: String {
        RecordingFormatters.size(fileSizeBytes)
    }
}

enum RecordingFormatters {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    /// Newest first, for the list.
    var sorted: [Recording] { recordings.sorted { $0.startedAt > $1.startedAt } }

    var totalSizeBytes: Int64 {
        recordings.reduce(0) { $0 + $1.fileSizeBytes }
    }

    let directory: URL

    private let indexFileName = "recordings.json"

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = base.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
        rescan()
    }

    func indexURL(for recording: Recording) -> URL {
        directory.appendingPathComponent(recording.folderName, isDirectory: true)
            .appendingPathComponent("index.m3u8")
    }

    func folderURL(for recording: Recording) -> URL {
        directory.appendingPathComponent(recording.folderName, isDirectory: true)
    }

    func add(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.append(recording)
        save()
    }

    func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            recordings.append(recording)
            save()
            return
        }
        recordings[index] = recording
        save()
    }

    func recording(id: String) -> Recording? {
        recordings.first { $0.id == id }
    }

    /// Delete the recording's folder and its metadata entry.
    func remove(_ recording: Recording) {
        try? FileManager.default.removeItem(at: folderURL(for: recording))
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    // MARK: - Persistence

    private var metadataURL: URL {
        directory.appendingPathComponent(indexFileName)
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        recordings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    // MARK: - Disk rescan

    /// Reconcile metadata with what is actually on disk:
    /// - entries whose folder is gone are dropped;
    /// - entries left in .recording by a previous run become .incomplete;
    /// - folders with an index.m3u8 but no metadata become .incomplete
    ///   entries (title falls back to the room id parsed from the folder).
    private func rescan() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }

        var changed = false
        var knownFolders = Set(recordings.map { $0.folderName })

        recordings = recordings.compactMap { recording in
            let folder = folderURL(for: recording)
            guard fm.fileExists(atPath: folder.path) else {
                changed = true
                return nil
            }
            if recording.status == .recording {
                var fixed = recording
                fixed.status = .incomplete
                fixed.endedAt = fixed.endedAt ?? Date()
                changed = true
                return fixed
            }
            return recording
        }
        knownFolders = Set(recordings.map { $0.folderName })

        for folder in folders where folder.hasDirectoryPath {
            let name = folder.lastPathComponent
            guard !knownFolders.contains(name) else { continue }
            let index = folder.appendingPathComponent("index.m3u8")
            guard fm.fileExists(atPath: index.path) else { continue }
            let (duration, size, count) = Self.probe(folder: folder)
            // Folder name: <platform>-<roomID>-<yyyyMMdd-HHmmss>
            let parts = name.split(separator: "-", maxSplits: 2).map(String.init)
            let platform = parts.first.flatMap(LivePlatform.init(rawValue:)) ?? .bilibili
            let roomID = parts.count > 1 ? parts[1] : "?"
            recordings.append(Recording(
                id: UUID().uuidString,
                roomID: roomID,
                platform: platform,
                title: "房间 \(roomID)",
                anchorName: "",
                quality: "",
                line: "",
                folderName: name,
                startedAt: Date(),
                endedAt: Date(),
                durationSeconds: duration,
                fileSizeBytes: size,
                segmentCount: count,
                hasGap: true,
                status: .incomplete,
                errorMessage: "上次录制未正常结束"
            ))
            changed = true
        }

        if changed { save() }
    }

    /// Read a recovered folder's local index to recover duration and
    /// segment count; size comes from the folder itself.
    private static func probe(folder: URL) -> (duration: Double, size: Int64, count: Int) {
        let fm = FileManager.default
        var size: Int64 = 0
        if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items {
                size += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
            }
        }
        let index = folder.appendingPathComponent("index.m3u8")
        guard let text = try? String(contentsOf: index, encoding: .utf8),
              case .media(let playlist) = HLSPlaylistParser.parse(text, baseURL: index) else {
            return (0, size, 0)
        }
        return (playlist.segments.reduce(0) { $0 + $1.duration }, size, playlist.segments.count)
    }

    /// Size of a folder on disk, for finalizing a recording.
    static func folderSize(_ folder: URL) -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { total, item in
            total + ((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0)
        }
    }
}
