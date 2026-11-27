// LivePlayerService.swift
// HAo Live — AVPlayer wrapper for live playback.
// Pure Live's player rules, re-implemented for AVPlayer:
//   - the player only reports .playing when the item is actually
//     ready; a failed item never shows a picture and never claims
//     to be playing (the old code set .playing immediately after
//     player.play(), so a dead stream looked "playing" on a black
//     screen with no error and no retry).
//   - on a hard failure the player advances to the next untried
//     stream (next line, then next quality — the stream list is
//     ordered best first) instead of sitting on a black screen.
//     Tried streams are remembered for this open() only; a manual
//     play / switch clears the memory (manual plays clear failure
//     memory first).
//   - plain-http stream URLs are upgraded to https (ATS blocks http).
//   - FLV / RTMP streams are reported honestly: AVPlayer cannot play
//     them, and the room needs an FLV-capable engine (VLC/mpv). The
//     FLV branch is the seam where that engine plugs in — the room
//     view renders the same player area either way.

import AVFoundation
import Combine

@MainActor
final class LivePlayerService: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentStream: PlayStream?
    @Published private(set) var availableStreams: [PlayStream] = []

    let player = AVPlayer()

    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var triedStreamIDs: Set<String> = []
    private var lastFailedItem: AVPlayerItem?

    var isPlaying: Bool {
        state == .playing
    }

    /// Open a room's streams. Picks the best stream by preference,
    /// or reports failure when the platform offered no stream.
    func open(streams: [PlayStream], preferredQuality: String?, preferredLine: String?) {
        availableStreams = streams
        triedStreamIDs = []
        lastFailedItem = nil
        guard let stream = StreamPicker.best(streams: streams, preferredQuality: preferredQuality, preferredLine: preferredLine) else {
            state = .failed("暂无可播放的线路")
            return
        }
        play(stream: stream)
    }

    func play(stream: PlayStream) {
        state = .loading
        currentStream = stream
        triedStreamIDs.insert(stream.id)
        detachItemObservers()
        // FLV / RTMP need an FLV-capable engine; AVPlayer cannot play
        // them. Skip to the next stream when the list has one; only
        // fail honestly when every stream is FLV.
        if stream.isFLV {
            if let next = availableStreams.first(where: { !triedStreamIDs.contains($0.id) }) {
                play(stream: next)
            } else {
                state = .failed("此直播为 FLV 格式，当前版本暂不支持播放")
            }
            return
        }
        let item = AVPlayerItem(url: stream.httpsURL)
        observe(item: item)
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func switchStream(_ stream: PlayStream) {
        guard stream != currentStream else { return }
        // Manual play clears the failure memory first.
        triedStreamIDs = []
        lastFailedItem = nil
        play(stream: stream)
    }

    func pause() {
        player.pause()
        if state == .playing { state = .paused }
    }

    func resume() {
        player.play()
        if state == .paused { state = .playing }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func stop() {
        detachItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStream = nil
        availableStreams = []
        triedStreamIDs = []
        lastFailedItem = nil
        state = .idle
    }

    // MARK: - Item observation

    private func observe(item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleItemStatus(observedItem.status, for: observedItem)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let failedItem = notification.object as? AVPlayerItem else { return }
            // Pull the values out before hopping: Notification is not
            // Sendable, so the Task must not capture it (Swift 6).
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放失败"
            Task { @MainActor in
                self.handleItemFailure(message, for: failedItem)
            }
        }
    }

    private func detachItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let observer = failureObserver {
            NotificationCenter.default.removeObserver(observer)
            failureObserver = nil
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, for item: AVPlayerItem) {
        // A stale callback for an item that is no longer current.
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            if state == .loading {
                state = .playing
                player.play()
            }
        case .failed:
            handleItemFailure(item.error?.localizedDescription ?? "播放失败", for: item)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// A hard error: advance to the next untried stream (next line,
    /// then next quality). When nothing is left, surface the real
    /// error. The same item's failure is handled once — the status
    /// callback and the failure notification can both fire for it.
    private func handleItemFailure(_ message: String, for item: AVPlayerItem) {
        guard lastFailedItem !== item else { return }
        lastFailedItem = item
        guard item === player.currentItem else { return }
        if let next = availableStreams.first(where: { !triedStreamIDs.contains($0.id) }) {
            play(stream: next)
            return
        }
        state = .failed(message)
    }
}
