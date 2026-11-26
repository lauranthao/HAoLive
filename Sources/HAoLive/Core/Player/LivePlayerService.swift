// LivePlayerService.swift
// HAo Live — AVPlayer wrapper for live playback (skeleton).
// MPV/IJK come later if needed; this leg only needs a working
// player shell: open a stream, play/pause, switch quality+line.

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

    var isPlaying: Bool {
        state == .playing
    }

    /// Open a room's streams. Picks the best stream by preference,
    /// or reports failure when the platform offered no stream.
    func open(streams: [PlayStream], preferredQuality: String?, preferredLine: String?) {
        availableStreams = streams
        guard let stream = StreamPicker.best(streams: streams, preferredQuality: preferredQuality, preferredLine: preferredLine) else {
            state = .failed("暂无可播放的线路")
            return
        }
        play(stream: stream)
    }

    func play(stream: PlayStream) {
        state = .loading
        currentStream = stream
        let item = AVPlayerItem(url: stream.url)
        player.replaceCurrentItem(with: item)
        player.play()
        state = .playing
    }

    func switchStream(_ stream: PlayStream) {
        guard stream != currentStream else { return }
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStream = nil
        availableStreams = []
        state = .idle
    }
}
