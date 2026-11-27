// AVPlayerEngine.swift
// HAo Live — the system player as a PlayerEngine (Pure Live's
// BetterPlayer chain: on iOS BetterPlayer IS AVPlayer).
//
// chen 2026-11-27 19:53: "留" — keep the system player as the
// fallback behind mpv (mpv first, this engine only for HLS).
// FLV / RTMP are excluded by canPlay; mpv is the only engine
// that plays them.
//
// This is the build 5 AVPlayer implementation, extracted
// unchanged into the PlayerEngine shape: the item only reports
// ready when it is actually readyToPlay, and a hard failure is
// reported to the service (which advances the sweep) instead of
// sitting on a black screen. Headers go in through
// AVURLAssetHTTPHeaderFieldsKey — AVPlayer sends no headers
// otherwise, which is one reason bare play URLs failed.

import AVFoundation
import Foundation
import UIKit

final class AVPlayerEngine: PlayerEngine {
    let name = "系统播放器"

    weak var delegate: (any PlayerEngineDelegate)?

    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var lastFailedItem: AVPlayerItem?
    private var opened = false
    private var paused = false
    private var firstFrameReported = false

    var videoView: UIView { playerView }

    var isPlaying: Bool { opened && !paused }

    init() {
        playerView.setPlayer(player)
    }

    /// HLS only — FLV / RTMP need mpv.
    func canPlay(_ stream: PlayStream) -> Bool {
        !stream.isFLV
    }

    func open(url: URL, headers: [String: String], format: String) {
        opened = false
        paused = false
        firstFrameReported = false
        lastFailedItem = nil
        detachItemObservers()
        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPHeaderFieldsKey: headers])
        }
        let item = AVPlayerItem(asset: asset)
        observe(item: item)
        player.replaceCurrentItem(with: item)
        player.play()
        opened = true
    }

    func play() {
        guard opened else { return }
        paused = false
        player.play()
    }

    func pause() {
        guard opened else { return }
        paused = true
        player.pause()
    }

    func stop() {
        guard opened else { return }
        opened = false
        paused = false
        firstFrameReported = false
        detachItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func setVideoFit(fill: Bool) {
        playerView.setFill(fill)
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
            if !firstFrameReported {
                firstFrameReported = true
                delegate?.engineDidRenderFirstFrame(self)
            }
            delegate?.engineDidBecomeReady(self)
        case .failed:
            handleItemFailure(item.error?.localizedDescription ?? "播放失败", for: item)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// The same item's failure is handled once — the status callback
    /// and the failure notification can both fire for it.
    private func handleItemFailure(_ message: String, for item: AVPlayerItem) {
        guard lastFailedItem !== item else { return }
        lastFailedItem = item
        guard item === player.currentItem else { return }
        delegate?.engine(self, didFailWith: message)
    }
}

/// Plain UIKit view hosting the AVPlayerLayer.
private final class AVPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func setPlayer(_ player: AVPlayer) {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    func setFill(_ fill: Bool) {
        playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
