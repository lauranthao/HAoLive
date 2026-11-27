// LivePlayerService.swift
// HAo Live — playback facade over the player engines.
// Pure Live's LivePlaybackController sweep, translated to Swift:
//   attempt(source, engine) fails -> next source on the same engine
//   -> sources exhausted -> next engine, sweep again (if allowed)
//   -> nothing left -> fail honestly. "Fails" means the engine
//   reported a hard error, or no frame appeared within the
//   source-ready timeout (18 s, Pure Live's sourceReadyTimeout).
// Engine order: mpv pinned first (when the libmpv module is
// present), then the system player for HLS only — the chain as
// Pure Live registers it (mediaKit -> IJK -> BetterPlayer; IJK's
// format coverage is a subset of mpv's, so it adds nothing here,
// and BetterPlayer on iOS IS AVPlayer). chen 2026-11-27 19:53
// decided to KEEP the system-player fallback ("留").
// Before the next engine, sources are re-resolved through
// sourceRefresh (Pure Live's onEngineFallbackSources: signed URLs
// are single-use, so a fresh resolve is needed per engine).
//
// The service only reports .playing when an engine actually shows
// a picture. Tried streams are remembered for this open() only;
// a manual play / switch clears the memory first.

import Combine
import Foundation
import UIKit

@MainActor
final class LivePlayerService: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    /// Pure Live's source-ready watchdog: no frame within 18 s means
    /// the attempt failed.
    static let sourceReadyTimeout: TimeInterval = 18

    @Published private(set) var state: State = .idle
    @Published private(set) var currentStream: PlayStream?
    @Published private(set) var availableStreams: [PlayStream] = []
    @Published private(set) var engineName: String = "—"

    /// The one container view the room embeds (inline and fullscreen
    /// share it — only one shows at a time). The active engine's
    /// video view is pinned inside it.
    let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()

    /// Re-resolve the room's streams (fresh signed URLs). Set by the
    /// room view, which owns the site + room. Called once before the
    /// next engine in the sweep, and by refresh().
    var sourceRefresh: (() async -> [PlayStream])?

    private var engines: [any PlayerEngine] = []
    private var candidates: [PlayStream] = []
    private var triedStreamIDs: Set<String> = []
    private var engineIndex = 0
    private var activeEngine: (any PlayerEngine)?
    private var watchdogTask: Task<Void, Never>?
    private var lastErrorMessage: String?
    private var refreshedForEngine = false
    private var generation = 0

    var isPlaying: Bool {
        state == .playing
    }

    /// Open a room's streams. Picks the best stream by preference,
    /// or reports failure when the platform offered no stream.
    func open(streams: [PlayStream], preferredQuality: String?, preferredLine: String?) {
        generation += 1
        cancelWatchdog()
        destroyEngines()
        engines = []
        availableStreams = streams
        triedStreamIDs = []
        engines = makeEngines()
        engineIndex = 0
        refreshedForEngine = false
        lastErrorMessage = nil
        guard let best = StreamPicker.best(streams: streams, preferredQuality: preferredQuality, preferredLine: preferredLine) else {
            state = .failed("暂无可播放的线路")
            return
        }
        candidates = [best] + streams.filter { $0.id != best.id }
        state = .loading
        tryNextCandidate()
    }

    /// Manual play: clears the failure memory first, tries this
    /// stream first, then the rest as fallback.
    func play(stream: PlayStream) {
        generation += 1
        cancelWatchdog()
        destroyEngines()
        engines = []
        triedStreamIDs = []
        engines = makeEngines()
        engineIndex = 0
        refreshedForEngine = false
        lastErrorMessage = nil
        candidates = [stream] + availableStreams.filter { $0.id != stream.id }
        state = .loading
        tryNextCandidate()
    }

    func switchStream(_ stream: PlayStream) {
        guard stream != currentStream else { return }
        // Manual play clears the failure memory first.
        play(stream: stream)
    }

    /// Re-resolve sources and reopen, keeping the current quality /
    /// line preference (Pure Live's refresh button).
    func refresh() {
        guard let refresh = sourceRefresh else { return }
        let generation = generation
        Task {
            let fresh = await refresh()
            guard generation == self.generation else { return }
            self.open(
                streams: fresh,
                preferredQuality: self.currentStream?.quality,
                preferredLine: self.currentStream?.line
            )
        }
    }

    func pause() {
        activeEngine?.pause()
        if state == .playing { state = .paused }
    }

    func resume() {
        activeEngine?.play()
        if state == .paused { state = .playing }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    /// Video fit for the active engine (Pure Live's video-fit button).
    func setVideoFit(fill: Bool) {
        activeEngine?.setVideoFit(fill: fill)
    }

    func stop() {
        generation += 1
        cancelWatchdog()
        activeEngine?.stop()
        destroyEngines()
        activeEngine = nil
        engines = []
        candidates = []
        currentStream = nil
        availableStreams = []
        triedStreamIDs = []
        lastErrorMessage = nil
        engineName = "—"
        state = .idle
    }

    // MARK: - Sweep

    private func makeEngines() -> [any PlayerEngine] {
        var list: [any PlayerEngine] = []
        #if canImport(Libmpv)
        let mpv = MpvPlayerEngine()
        if mpv.isAvailable {
            list.append(mpv)
        }
        #endif
        list.append(AVPlayerEngine())
        return list
    }

    private func destroyEngines() {
        #if canImport(Libmpv)
        for engine in engines {
            (engine as? MpvPlayerEngine)?.destroy()
        }
        #endif
    }

    /// Next (engine, candidate) pair. When an engine exhausts its
    /// candidates, sources are re-resolved once, then the next
    /// engine sweeps the fresh list.
    private func tryNextCandidate() {
        cancelWatchdog()
        while engineIndex < engines.count {
            let engine = engines[engineIndex]
            if let candidate = candidates.first(where: { !triedStreamIDs.contains($0.id) && engine.canPlay($0) }) {
                attempt(engine: engine, stream: candidate)
                return
            }
            if !refreshedForEngine, let refresh = sourceRefresh {
                refreshedForEngine = true
                engineIndex += 1
                let generation = generation
                Task {
                    let fresh = await refresh()
                    guard generation == self.generation else { return }
                    self.availableStreams = fresh
                    self.candidates = fresh
                    self.tryNextCandidate()
                }
                return
            }
            engineIndex += 1
            refreshedForEngine = false
        }
        if !availableStreams.isEmpty,
           availableStreams.allSatisfy(\.isFLV),
           !engines.contains(where: { $0.name == "mpv" }) {
            state = .failed("此直播为 FLV 格式，当前版本暂不支持播放")
        } else {
            state = .failed(lastErrorMessage ?? "暂无可播放的线路")
        }
    }

    private func attempt(engine: any PlayerEngine, stream: PlayStream) {
        triedStreamIDs.insert(stream.id)
        currentStream = stream
        engineName = engine.name
        state = .loading
        activeEngine = engine
        engine.delegate = self
        attachVideoView(engine.videoView)
        engine.open(url: stream.httpsURL, headers: stream.headers, format: stream.format)
        startWatchdog(for: engine)
    }

    private func attachVideoView(_ view: UIView) {
        videoContainerView.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        videoContainerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            view.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor),
        ])
    }

    // MARK: - Watchdog

    private func startWatchdog(for engine: any PlayerEngine) {
        cancelWatchdog()
        let generation = generation
        watchdogTask = Task {
            try? await Task.sleep(for: .seconds(Self.sourceReadyTimeout))
            guard generation == self.generation,
                  !Task.isCancelled,
                  self.state == .loading,
                  self.activeEngine === engine else { return }
            self.lastErrorMessage = "播放超时"
            self.tryNextCandidate()
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }
}

// MARK: - PlayerEngineDelegate

extension LivePlayerService: PlayerEngineDelegate {
    func engineDidBecomeReady(_ engine: any PlayerEngine) {
        guard engine === activeEngine, state == .loading else { return }
        cancelWatchdog()
        state = .playing
        engine.play()
    }

    func engine(_ engine: any PlayerEngine, didFailWith message: String) {
        guard engine === activeEngine, state == .loading else { return }
        lastErrorMessage = message
        tryNextCandidate()
    }

    func engineDidRenderFirstFrame(_ engine: any PlayerEngine) {
        // mpv reports ready on the first frame itself; the watchdog
        // is cancelled there. Nothing extra to do here.
    }
}
