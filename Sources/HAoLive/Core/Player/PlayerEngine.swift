// PlayerEngine.swift
// HAo Live — one playback backend behind LivePlayerService.
// wzgrx/PureLive v4: mpv is the only engine ("the only engine
// in v4"), and chen 19:03 decided no system player, only mpv.
// The facade sweeps candidates on that one engine, and the
// engine reports ready only when it can actually show a
// picture. A hard error — or an open that never shows a frame
// within the watchdog — advances the sweep to the next candidate.

import Foundation
import UIKit

/// One playback backend. Engines are created once by the service and
/// reused across opens; `open` replaces the current media.
///
/// @MainActor (build 7, primary #25): the protocol and the engine
/// class are main-actor-isolated. The #23 fix — changing the Task
/// hops from `[weak self]` to a strong capture — did not take, because
/// the error was never the capture list: a non-Sendable, nonisolated
/// `self` cannot be *used* inside a `Task { @MainActor in }` at all
/// (passing it as the delegate's engine argument, or reading its
/// @MainActor view). With the class @MainActor, `self` is already
/// main-actor-isolated, so the hops are legal. Only libmpv's own
/// threads (event loop, render callback) run off the main actor, and
/// those paths are `nonisolated` with explicit hops — see
/// MpvPlayerEngine.
@MainActor protocol PlayerEngine: AnyObject {
    /// "mpv" — shown in the player UI and logs.
    var name: String { get }

    /// Whether this engine can play the stream's container at all
    /// (mpv plays everything we offer; a GL-stalled engine
    /// reports false until it is recreated).
    func canPlay(_ stream: PlayStream) -> Bool

    /// The view this engine renders into. The service puts it in its
    /// container view and swaps it when the active engine changes.
    var videoView: UIView { get }

    var delegate: (any PlayerEngineDelegate)? { get set }

    /// Open a URL with per-request headers (Pure Live passes the
    /// playback headers into the player: Referer / UA / Cookie).
    /// `format` is the stream's container hint ("flv" / "hls" / "").
    func open(url: URL, headers: [String: String], format: String)

    func play()
    func pause()
    func stop()

    /// Video fit: false = aspect-fit (letterbox), true = fill
    /// (crop). Pure Live's video-fit button cycles the fit list.
    func setVideoFit(fill: Bool)

    var isPlaying: Bool { get }
}

/// Engine -> service callbacks. All calls arrive on the main actor
/// (engines hop to it before calling). The protocol is @MainActor so
/// the @MainActor LivePlayerService can conform — a nonisolated
/// protocol cannot be witnessed by main-actor-isolated code
/// (primary #19: "conformance crosses into main actor-isolated
/// code"). Engines must therefore call these only from a @MainActor
/// context (Task { @MainActor in } / @MainActor methods).
@MainActor protocol PlayerEngineDelegate: AnyObject {
    /// The engine is showing a picture. This is the sweep's success
    /// signal — the service reports .playing only after this.
    func engineDidBecomeReady(_ engine: any PlayerEngine)

    /// A hard error: the sweep advances to the next candidate.
    func engine(_ engine: any PlayerEngine, didFailWith message: String)

    /// First video frame rendered (watchdog progress signal).
    func engineDidRenderFirstFrame(_ engine: any PlayerEngine)

    /// Cache state changed (buffered seconds or stall flip): the
    /// service refreshes the on-screen tag.
    func engineCacheStateDidChange(_ engine: any PlayerEngine)
}
