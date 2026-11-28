// MpvPlayerEngine.swift
// HAo Live — libmpv as a PlayerEngine (Pure Live's pinned default
// engine: media_kit = mpv). Plays FLV + HLS + RTMP.
//
// INTEGRATION (landed): libmpv comes from MPVKit via SPM —
// package github.com/mpvkit/MPVKit, exact 1.1.0-n9.0.2, LGPL
// product MPVKit (binary target Libmpv; NOT the -GPL product).
// The pbxproj carries the XCRemoteSwiftPackageReference +
// XCSwiftPackageProductDependency by hand: the pbxproj generator
// (~/workspace/.tmp/gen_haolive_pbx.py) has NO package support,
// so never regen it without re-adding these refs. xcodebuild
// resolves the package on Bitrise (exact version pin); no
// Package.resolved is committed yet.
//
// RENDERING: two paths, one engine. On device the GPU path is
// used — MpvGLRenderer (media_kit's TextureHW, ported): mpv's
// OpenGL render API draws into an FBO texture backed by a
// CVPixelBuffer, which an AVSampleBufferDisplayLayer shows
// zero-copy. libmpv exposes no Metal render API (render.h has
// only MPV_RENDER_API_TYPE_OPENGL + the software renderer), and
// OpenGL ES is what media_kit still ships on iOS (verified
// 2026-11-28 against media_kit_video's current docs/changelog:
// iOS = MPV_RENDER_API_TYPE_OPENGL + pixel buffer, software =
// MPV_RENDER_API_TYPE_SW + pixel buffer; only macOS moved to
// METAL). The SOFTWARE renderer stays as the fallback: it is used
// on the simulator (media_kit disables GL there — "an
// incompatibility with OpenGL ES") and whenever EAGLContext
// creation fails. Build 11: the fallback is no longer silent —
// the engine records which path is active (renderPath) and the
// GL failure reason, so 原画 lag can finally be attributed to a
// path instead of guessed at. Since build 9 the SW path is capped
// at 1280x720, and zero-copy: frames render into a two-slot pool
// and the CGImage reads the slot directly (FrameBufferPool),
// instead of a Data(bytes:) memcpy per frame. The GL path renders
// at native video size up to 1920x1080 — the GPU scales, the CPU
// never sees the pixels.
//
// ENGINE (build 11, wzgrx v4 + chen 19:03): mpv is the ONLY
// engine. Build 9/10 sent HLS to the system player first — chen
// 2026-11-28: that was my own deviation, wrong — and the system
// player fallback is deleted with it (AVPlayerEngine.swift gone).
//
// OPTIONS: wzgrx MpvEngineConfig.liveProperties, verbatim:
// 1 MiB probe, 1 s analyze, 15 s network timeout, cache-secs 6,
// 32 MB max-bytes, 4 MB max-back-bytes, 2 s readahead,
// force-seekable yes, hwdec auto-safe by default. Per open:
// hwdec, http-proxy, volume-gain (wzgrx MpvEngine.open).
//
// ENUMS: mpv's C enums are used as their BARE constants
// (MPV_FORMAT_FLAG, MPV_EVENT_SHUTDOWN, MPV_RENDER_PARAM_API_TYPE,
// ...), NOT the dotted Swift members (mpv_format.flag,
// mpv_event_id.shutdown, ...). Swift does not import these enum
// cases under their stripped names — Bitrise primary #21 failed on
// all 17 dotted references, and the Linux Swift 6.2 toolchain
// reproduces the same "has no member" errors against MPVKit's real
// headers, while the bare constants typecheck in every position
// (args, struct inits, switch cases, comparisons). Do not
// "modernise" them back to dotted form.

#if canImport(Libmpv)
import Libmpv
import CoreGraphics
import Foundation
import os
import UIKit

@MainActor final class MpvPlayerEngine: PlayerEngine {
    let name = "mpv"

    /// Which render path this engine is actually using (build 11).
    /// The GL path used to fail silently: tryEnableGL returned
    /// false and the engine fell back to the software renderer
    /// with no log and no state anywhere — the likely cause of
    /// 原画 lag on all platforms (chen 2026-11-28: every platform
    /// lags at 原画). The service shows this in engineName and the
    /// log, so a device report can finally say GL or SW.
    enum RenderPath: Equatable {
        case gl
        case sw
        case glFailed(String)
    }

    private(set) var renderPath: RenderPath = .sw

    /// The decoder mpv is actually using (mpv `hwdec-current`:
    /// "videotoolbox" / "videotoolbox-copy" / "no" = software decode).
    /// Written from the event loop (nonisolated), read on the main
    /// actor by the service's display name. Empty until the first
    /// property event arrives. Build 11 never read this: a silent
    /// software-decode fallback — the prime 原画 lag suspect — was
    /// invisible next to the render path.
    nonisolated(unsafe) var hwdecCurrent: String = ""

    /// A presented-frame stall marks the mpv engine unusable
    /// (canPlay false) so the sweep does not retry the same dead
    /// GPU path on the next candidate. The service recreates the
    /// engine once for it (wzgrx recovery step 3) — see the
    /// delegate below. Lives outside the simulator-gated GL block:
    /// canPlay (line 160) and LivePlayerService read it on every
    /// build, and on the simulator GL never activates so it stays
    /// false (primary #38).
    private(set) var glStalled = false
    private func reportGLStalled() {
        guard !glStalled else { return }
        glStalled = true
        renderPath = .glFailed(MpvGLRenderer.lastFailureReason ?? "GPU 渲染槽位为空")
        delegate?.engine(self, didFailWith: "GPU 渲染失败，已切换线路")
    }

    /// hwdec mode from SettingsStore (Pure Live's hwdec setting):
    /// auto / auto-safe / no. Set by the room view before open();
    /// the engine is created per open, so the current value
    /// applies on the next room entry.
    static var hwdecMode = "auto-safe"

    weak var delegate: (any PlayerEngineDelegate)?

    // The mpv-facing state below is touched from libmpv's own
    // threads (the event loop and the render thread), so it is
    // nonisolated(unsafe): libmpv is designed for multi-threaded use
    // (mpv_wait_event blocks on one thread while commands go from
    // others), and every other property stays main-actor-isolated.
    // `destroying` is a loop flag; `renderPending` a coalescing flag
    // (a torn read only costs one extra frame render); `renderSize`
    // is written by the property-change handler and read by the
    // render thread — a mismatched pair only sizes one frame wrong.
    private nonisolated(unsafe) var handle: OpaquePointer?
    private nonisolated(unsafe) var renderContext: OpaquePointer?
    /// +1 retain handed to libmpv's render update callback
    /// (passRetained): the callback may fire after the service drops
    /// the engine, so an unretained self would dangle. Released in
    /// the event loop's teardown, after the render context is freed
    /// (which unregisters the callback).
    private nonisolated(unsafe) var renderCallbackToken: UnsafeMutableRawPointer?
    private var eventThread: Thread?
    private nonisolated(unsafe) var destroying = false
    private var opened = false
    private var paused = false
    private var firstFrameReported = false
    private nonisolated(unsafe) var renderPending = false
    private nonisolated(unsafe) var renderSize = CGSize(width: 1280, height: 720)
    /// Video size for the GL renderer (native size, capped
    /// 1920x1080 — the GPU scales). Updated by the same property
    /// observations as renderSize; the GL renderer dedupes.
    private nonisolated(unsafe) var glVideoSize = CGSize.zero
    /// The GPU renderer, when the device path is active. Nil on
    /// the simulator and when EAGL is unavailable — the SW path
    /// below then serves instead.
    #if canImport(OpenGLES)
    private nonisolated(unsafe) var glRenderer: MpvGLRenderer?
    private var glVideoViewInstance: MpvGLVideoView?
    #endif
    /// Two-slot frame pool (see FrameBufferPool): renderFrame renders
    /// into the idle slot and hands that slot's memory to the CGImage
    /// with no copy; the provider's release callback returns the slot.
    /// Internally locked — safe to touch from the render thread, the
    /// event loop and the provider callback alike.
    private nonisolated(unsafe) var framePool = FrameBufferPool()

    // Assigned in the init body (primary #20's lesson: when the class
    // was nonisolated, a stored-property default was checked against
    // the type's isolation, so MpvVideoView() could not be a default
    // even with a @MainActor init). The class is @MainActor now, so a
    // default would work — the init-body assignment stays as-is.
    private let videoViewInstance: MpvVideoView
    /// The GL view when the GPU path is active; the service only
    /// ever sees `videoView`, which picks the active one.
    var videoView: UIView {
        #if canImport(OpenGLES)
        if let glView = glVideoViewInstance { return glView }
        #endif
        return videoViewInstance
    }

    var isPlaying: Bool { opened && !paused }

    /// False when mpv_create / mpv_initialize failed — the service
    /// skips an unusable engine instead of sweeping into it.
    var isAvailable: Bool { handle != nil }

    func canPlay(_ stream: PlayStream) -> Bool {
        // mpv plays everything we offer (FLV / HLS / RTMP / mp4).
        // A stalled GL engine is unusable — the sweep must move to
        // the next engine instead of retrying the dead GPU path.
        if glStalled { return false }
        return true
    }

    // MARK: - Lifecycle

    // MpvVideoView() is a @MainActor-isolated initializer (Swift 6 /
    // iOS 26 SDK); the whole class is @MainActor now (primary #25),
    // so the init is too. Called only from the @MainActor service's
    // makeEngines().
    @MainActor init() {
        self.videoViewInstance = MpvVideoView()
        guard let handle = mpv_create() else { return }
        self.handle = handle
        applyOptions(handle)
        guard mpv_initialize(handle) == 0 else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            return
        }
        // GPU path first on device (media_kit's rule: the simulator
        // never gets GL). When it cannot be built, the failure
        // reason is recorded (MpvGLRenderer.lastFailureReason) and
        // the engine falls through to the software renderer below —
        // and says so, instead of the old silent fallback.
        #if canImport(OpenGLES) && !targetEnvironment(simulator)
        if tryEnableGL(handle) {
            renderPath = .gl
            observeVideoSize(handle)
            startEventThread()
            return
        }
        let glReason = MpvGLRenderer.lastFailureReason ?? "EAGL 不可用"
        renderPath = .glFailed(glReason)
        Logger(subsystem: "live.haostudio", category: "player").error("mpv GL 路径失败，走软渲染：\(glReason, privacy: .public)")
        #endif
        createRenderContext(handle)
        startEventThread()
    }

    /// Build the GPU renderer + its view. True when the GL path is
    /// live; false leaves the engine to the SW path. Called only
    /// from init (main actor).
    #if canImport(OpenGLES) && !targetEnvironment(simulator)
    private func tryEnableGL(_ handle: OpaquePointer) -> Bool {
        let glView = MpvGLVideoView()
        guard let renderer = MpvGLRenderer(handle: handle, displayLayer: glView.sampleLayer, onFirstFrame: { [weak self] in
            Task { @MainActor in self?.reportGLFirstFrame() }
        }) else { return false }
        renderer.onStalled = { [weak self] in
            Task { @MainActor in self?.reportGLStalled() }
        }
        self.glVideoViewInstance = glView
        self.glRenderer = renderer
        return true
    }

    /// First GL frame: same ready signal the SW path reports from
    /// its first rendered frame.
    private func reportGLFirstFrame() {
        guard !firstFrameReported else { return }
        firstFrameReported = true
        delegate?.engineDidRenderFirstFrame(self)
        delegate?.engineDidBecomeReady(self)
    }
    #endif

    /// Tear the mpv instance down. The service calls this from stop()
    /// and drops the engine afterwards — a destroyed engine is never
    /// re-opened; the service creates a fresh one on the next open().
    /// The event thread owns the final free, so this only signals.
    /// nonisolated: deinit (nonisolated) calls it, and it only touches
    /// nonisolated(unsafe) state.
    nonisolated func destroy() {
        guard let handle else { return }
        destroying = true
        mpv_wakeup(handle)
    }

    deinit {
        destroy()
    }

    // MARK: - PlayerEngine

    func open(url: URL, headers: [String: String], format: String) {
        guard let handle else {
            // The class is @MainActor, so `self` in the hop below is
            // main-actor-isolated and legal (primary #25 — the #23
            // strong-capture fix did not take because the error was
            // never the capture list).
            Task { @MainActor in
                self.delegate?.engine(self, didFailWith: "mpv 未能初始化")
            }
            return
        }
        opened = false
        paused = false
        firstFrameReported = false
        // Per-open properties (wzgrx MpvEngine.open + openMpvMediaInput):
        // hwdec, http-proxy, volume-gain. Nothing else is set per
        // open — force-seekable (yes) lives in liveProperties, the
        // demuxer format is only forced for RTP (mpegs), which
        // HAoLive has no source for, and cache-pause is not set
        // by wzgrx at all. The old per-open force-seekable=no /
        // cache-pause=no / demuxer-lavf-format=hls lines undid
        // the table and are deleted.
        // Per-open, as properties (wzgrx MpvEngine.open): hwdec follows
        // the setting, http-proxy empty, volume-gain 0 (HAoLive has no
        // gain setting). These MUST be properties, not options — see
        // setPropertyString. The old code set http-proxy / headers /
        // user-agent with setOption after initialize.
        setPropertyString(handle, "hwdec", Self.hwdecMode)
        setPropertyString(handle, "http-proxy", "")
        setPropertyString(handle, "volume-gain", "0")
        if !headers.isEmpty {
            // "Field: value, Field: value" — our headers carry no commas.
            let fields = headers
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            setPropertyString(handle, "http-header-fields", fields)
            // Header keys arrive lowercase from PlaybackHeaders
            // ("user-agent"), so look the UA up case-insensitively —
            // the exact-case lookup silently never matched, and mpv
            // fell back to its default UA.
            if let userAgent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                setPropertyString(handle, "user-agent", userAgent)
            }
        }
        // mpv_command takes const char **: the array must hold
        // UnsafePointer<CChar> (not mutable) — primary #22 failed with
        // "conflicting arguments to generic parameter 'Pointee'" when the
        // array held UnsafeMutablePointer<CChar>. The strdup'd buffers are
        // kept in `owned` so free() still gets the mutable pointers back.
        let owned: [UnsafeMutablePointer<CChar>?] = [strdup("loadfile"), strdup(url.absoluteString), strdup("replace")]
        defer { owned.forEach { if let p = $0 { free(p) } } }
        var args: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } } + [nil]
        // const char ** = mutable outer pointer to const char *: the array
        // holds UnsafePointer<CChar> but must go through the MUTABLE buffer
        // pointer (withUnsafeMutableBufferPointer), not withUnsafeBufferPointer.
        let result = args.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
        }
        if result < 0 {
            Task { @MainActor in
                self.delegate?.engine(self, didFailWith: self.errorMessage(result))
            }
            return
        }
        opened = true
        paused = false
    }

    func play() {
        guard let handle, opened else { return }
        paused = false
        setPropertyFlag(handle, "pause", false)
    }

    func pause() {
        guard let handle, opened else { return }
        paused = true
        setPropertyFlag(handle, "pause", true)
    }

    func stop() {
        guard let handle, opened else { return }
        opened = false
        paused = false
        firstFrameReported = false
        #if canImport(OpenGLES)
        glVideoViewInstance?.flush()
        #endif
        mpv_command_string(handle, "stop")
    }

    func setVideoFit(fill: Bool) {
        #if canImport(OpenGLES)
        if let glView = glVideoViewInstance {
            glView.setFill(fill)
            return
        }
        #endif
        videoViewInstance.setFill(fill)
    }

    // MARK: - Options (Pure Live's MediaKitLiveProperties table)

    private func applyOptions(_ handle: OpaquePointer) {
        // wzgrx MpvEngineConfig.liveProperties, verbatim
        // (packages/live_player/lib/src/mpv_options.dart), plus the
        // media_kit defaults the reference inherits (third_party/
        // media_kit/lib/.../real.dart _create properties, marked
        // "media_kit"): scale/dscale/dither/hr-seek/demuxer-lavf-o.
        // iOS-only addition, marked: vo=libmpv is the render API
        // the GL path needs (wzgrx iOS has only libmpv as video
        // output driver; media_kit_video defaults vo to 'libmpv'
        // and sets it as a property). ao is left unset like wzgrx
        // (mpv's iOS default is audiounit). Everything else is
        // exactly wzgrx's table — the old 3.x values (2 MiB probe,
        // 30 s cache, 8 s readahead, 96 MB buffer, low-end lowres
        // preset, framedrop) are gone: wzgrx measured first frame
        // 1802 ms -> 708 ms with the 1 MiB / 1 s probe, and plays
        // 原画 on these values.
        setOption(handle, "vo", "libmpv") // iOS render API (see above)
        // hwdec follows the setting (Pure Live's hwdec setting:
        // auto / auto-safe / no; wzgrx default auto-safe).
        setOption(handle, "hwdec", Self.hwdecMode)
        setOption(handle, "hwdec-software-fallback", "1")
        setOption(handle, "force-seekable", "yes")
        // media_kit: demuxer-lavf-o carries the protocol whitelist
        // (plus seg_max_retry and allowed_extensions). The old
        // top-level "protocol-whitelist" line is deleted: mpv has no
        // such top-level option (protocol_whitelist is a libavformat
        // option), so the set was a silent no-op — FFmpeg's default
        // already allows these top-level protocols, which is why
        // nothing visibly broke.
        setOption(handle, "demuxer-lavf-o", "seg_max_retry=5,strict=experimental,allowed_extensions=ALL,protocol_whitelist=[httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt]")
        setOption(handle, "demuxer-lavf-probesize", "1048576")
        setOption(handle, "demuxer-lavf-analyzeduration", "1")
        setOption(handle, "network-timeout", "15")
        setOption(handle, "cache", "yes")
        setOption(handle, "cache-on-disk", "no")
        setOption(handle, "cache-secs", "6")
        setOption(handle, "demuxer-max-bytes", "33554432")
        setOption(handle, "demuxer-max-back-bytes", "4194304")
        setOption(handle, "demuxer-donate-buffer", "no")
        setOption(handle, "demuxer-readahead-secs", "2")
        // media_kit defaults (real.dart _create), which the reference
        // inherits: cheap bilinear scaling, no dithering / downscaling
        // correction, hr-seek without framedrop. HAoLive used to rely
        // on mpv's built-in defaults for these instead.
        setOption(handle, "scale", "bilinear")
        setOption(handle, "dscale", "bilinear")
        setOption(handle, "dither", "no")
        setOption(handle, "correct-downscaling", "no")
        setOption(handle, "linear-downscaling", "no")
        setOption(handle, "sigmoid-upscaling", "no")
        setOption(handle, "hdr-compute-peak", "no")
        setOption(handle, "hr-seek", "yes")
        setOption(handle, "hr-seek-framedrop", "no")
        #if DEBUG
        setOption(handle, "msg-level", "all=v")
        #else
        setOption(handle, "msg-level", "all=warn")
        #endif
    }

    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        name.withCString { namePtr in
            value.withCString { valuePtr in
                _ = mpv_set_option_string(handle, namePtr, valuePtr)
            }
        }
    }

    /// mpv_set_property_string: the runtime API. mpv_set_option_string
    /// is pre-init only ("you can't normally set options during
    /// runtime" — mpv client.h); per-open values must go through here,
    /// exactly as wzgrx MpvEngine.open does (_setProperty). The old
    /// per-open setOption calls (http-proxy, headers, user-agent) used
    /// the pre-init API after initialize, so whether they ever applied
    /// was unverified — return values are ignored everywhere.
    private func setPropertyString(_ handle: OpaquePointer, _ name: String, _ value: String) {
        name.withCString { namePtr in
            value.withCString { valuePtr in
                _ = mpv_set_property_string(handle, namePtr, valuePtr)
            }
        }
    }

    private func setPropertyFlag(_ handle: OpaquePointer, _ name: String, _ value: Bool) {
        name.withCString { namePtr in
            var flag: Int64 = value ? 1 : 0
            _ = mpv_set_property(handle, namePtr, MPV_FORMAT_FLAG, &flag)
        }
    }

    /// Pure C call, no instance state — nonisolated so the event-loop
    /// handler can use it.
    nonisolated private func errorMessage(_ code: Int32) -> String {
        guard let cString = mpv_error_string(code) else { return "播放失败" }
        return String(cString: cString)
    }

    // MARK: - Render context (software renderer)

    private func createRenderContext(_ handle: OpaquePointer) {
        "sw".withCString { apiPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var context: OpaquePointer?
            let result = params.withUnsafeMutableBufferPointer { buffer in
                mpv_render_context_create(&context, handle, buffer.baseAddress)
            }
            guard result == 0, let context else { return }
            renderContext = context
            let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
                guard let raw else { return }
                Unmanaged<MpvPlayerEngine>.fromOpaque(raw).takeUnretainedValue().renderUpdateRequested()
            }
            // passRetained: the callback borrows (takeUnretainedValue),
            // the +1 is released in the event loop's teardown.
            let token = Unmanaged.passRetained(self).toOpaque()
            renderCallbackToken = token
            mpv_render_context_set_update_callback(context, callback, token)
        }
        observeVideoSize(handle)
    }

    private func observeVideoSize(_ handle: OpaquePointer) {
        // dwidth/dheight drive the render buffer size; hwdec-current
        // (userdata 3) reports the decoder actually in use.
        "dwidth".withCString { name in
            _ = mpv_observe_property(handle, 1, name, MPV_FORMAT_INT64)
        }
        "dheight".withCString { name in
            _ = mpv_observe_property(handle, 2, name, MPV_FORMAT_INT64)
        }
        "hwdec-current".withCString { name in
            _ = mpv_observe_property(handle, 3, name, MPV_FORMAT_STRING)
        }
    }

    /// Called on libmpv's render thread when a new frame is available.
    /// nonisolated: the C update callback (see createRenderContext)
    /// and the event loop call this off the main actor. The GPU path
    /// owns its own coalescing; the SW path uses renderPending.
    nonisolated private func renderUpdateRequested() {
        #if canImport(OpenGLES)
        if let gl = glRenderer {
            gl.renderUpdateRequested()
            return
        }
        #endif
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.renderFrame()
        }
    }

    /// Runs on a background queue (see renderUpdateRequested).
    /// nonisolated: touches only nonisolated(unsafe) render state,
    /// then hops to the main actor for the view + delegate. The
    /// first-frame flag is read and set inside the hop — the render
    /// thread must not touch @MainActor state.
    ///
    /// Zero-copy: the frame is rendered into the pool's idle slot and
    /// the CGImage reads that slot directly (no Data(bytes:) memcpy
    /// per frame — the build 8 lag at 1080p). The slot is returned by
    /// the provider's release callback when the image is done; if
    /// both slots are still on screen the frame is skipped instead of
    /// blocking (framedrop is on).
    nonisolated private func renderFrame() {
        defer { renderPending = false }
        guard let context = renderContext else { return }
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        guard width > 0, height > 0 else { return }
        let stride = width * 4
        let size = stride * height
        guard let slot = framePool.acquire(size: size) else { return }
        var swSize: [Int32] = [Int32(width), Int32(height)]
        var strideValue: Int = stride
        // SW_POINTER's data is the frame buffer itself (void*), NOT
        // the address of a pointer variable: passing &pointer made
        // libmpv write the whole frame onto the stack, crashing on
        // the first frame of every room (build 7; reproduced against
        // system libmpv — segfault inside mpv_render_context_render,
        // fixed by this one line, 188 frames clean).
        let image: CGImage? = "rgba".withCString { formatPtr in
            swSize.withUnsafeMutableBufferPointer { sizePtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: formatPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(&strideValue)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: slot.ptr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                let result = params.withUnsafeMutableBufferPointer { buffer in
                    mpv_render_context_render(context, buffer.baseAddress)
                }
                guard result == 0 else { return nil }
                // rgba in memory = R,G,B,A per pixel; the video is opaque.
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                // The provider retains this context (+1); its release
                // callback takes it back and returns the slot to the
                // pool. If the provider itself cannot be created, the
                // retain is balanced here and the slot is freed.
                let contextBox = Unmanaged.passRetained(FrameProviderContext(pool: framePool, index: slot.index)).toOpaque()
                guard let dataProvider = CGDataProvider(
                    dataInfo: contextBox,
                    data: slot.ptr,
                    size: size,
                    releaseData: { info, _, _ in
                        guard let info else { return }
                        Unmanaged<FrameProviderContext>.fromOpaque(info).takeRetainedValue().release()
                    }
                ) else {
                    Unmanaged<FrameProviderContext>.fromOpaque(contextBox).takeRetainedValue()
                    framePool.release(index: slot.index)
                    return nil
                }
                return CGImage(
                    width: width, height: height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                    space: colorSpace, bitmapInfo: bitmapInfo,
                    provider: dataProvider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent
                )
            }
        }
        guard let image else {
            framePool.release(index: slot.index)
            return
        }
        Task { @MainActor in
            self.videoViewInstance.display(image)
            if !self.firstFrameReported {
                self.firstFrameReported = true
                self.delegate?.engineDidRenderFirstFrame(self)
                self.delegate?.engineDidBecomeReady(self)
            }
        }
    }

    // MARK: - Event loop (dedicated thread; mpv_wait_event blocks)

    private func startEventThread() {
        let thread = Thread { [weak self] in
            self?.eventLoop()
        }
        thread.name = "live.mpv.event"
        thread.qualityOfService = .userInitiated
        eventThread = thread
        thread.start()
    }

    /// Dedicated thread; mpv_wait_event blocks. nonisolated: touches
    /// only nonisolated(unsafe) mpv state, and the handlers below
    /// extract plain values before hopping to the main actor.
    nonisolated private func eventLoop() {
        guard let handle else { return }
        while !destroying {
            guard let event = mpv_wait_event(handle, 1.0) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_SHUTDOWN:
                destroying = true
            case MPV_EVENT_END_FILE:
                handleEndFile(event.pointee)
            case MPV_EVENT_VIDEO_RECONFIG:
                renderUpdateRequested()
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event.pointee)
            default:
                break
            }
        }
        // The thread owns the final teardown: render context first,
        // then the handle, then the frame buffer. Freeing the render
        // context unregisters the update callback, so the retained
        // self it held is released here, after the free. The GPU
        // path's context lives in the renderer — tear it down
        // instead of the (nil) SW one.
        #if canImport(OpenGLES)
        if let gl = glRenderer {
            gl.teardown()
            glRenderer = nil
        }
        #endif
        if let context = renderContext {
            mpv_render_context_free(context)
            renderContext = nil
        }
        if let token = renderCallbackToken {
            renderCallbackToken = nil
            Unmanaged<MpvPlayerEngine>.fromOpaque(token).release()
        }
        mpv_terminate_destroy(handle)
        self.handle = nil
        // Slots still on screen are freed by their provider release
        // callbacks (teardown marks the pool dead for that); idle
        // slots are freed here.
        framePool.teardown()
    }

    /// nonisolated (called from the event loop): extract the failure
    /// message as a plain String, then hop — the `opened` check and
    /// the delegate call both live on the main actor.
    nonisolated private func handleEndFile(_ event: mpv_event) {
        // A live stream ending (EOF) or erroring is a hard failure —
        // the sweep advances to the next candidate.
        guard let data = event.data else { return }
        let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        let message: String
        switch endFile.reason {
        case MPV_END_FILE_REASON_ERROR:
            message = endFile.error != 0 ? errorMessage(endFile.error) : "播放失败"
        case MPV_END_FILE_REASON_EOF:
            message = "直播流已结束"
        default:
            return
        }
        Task { @MainActor in
            guard self.opened else { return }
            self.delegate?.engine(self, didFailWith: message)
        }
    }

    /// nonisolated (called from the event loop): renderSize is
    /// nonisolated(unsafe) — written here, read by the render thread
    /// — so it is updated directly, no hop.
    nonisolated private func handlePropertyChange(_ event: mpv_event) {
        guard let data = event.data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        // hwdec-current (userdata 3) is a string, not an int: the
        // decoder actually in use. mpv sends it when decoding starts;
        // "no" means software decode.
        if event.reply_userdata == 3 {
            guard property.format == MPV_FORMAT_STRING, let valuePtr = property.data,
                  let cString = valuePtr.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return }
            hwdecCurrent = String(cString: cString)
            return
        }
        guard property.format == MPV_FORMAT_INT64, let valuePtr = property.data else { return }
        let value = valuePtr.assumingMemoryBound(to: Int64.self).pointee
        guard value > 0 else { return }
        // reply_userdata lives on mpv_event, not on mpv_event_property
        // (which only has name/format/data) — primary #22.
        // SW cap 1280x720: the software renderer rasterises every
        // pixel on the CPU, and 1080p rooms were the build 8 lag
        // (all formats go to mpv now — no system player first;
        // this cap is for rooms that fall back to the SW path).
        // The GL path renders at native size up to 1920x1080 — the
        // GPU scales.
        if event.reply_userdata == 1 {
            renderSize.width = CGFloat(min(value, 1280))
            #if canImport(OpenGLES)
            glVideoSize.width = CGFloat(min(value, 1920))
            glRenderer?.resize(to: glVideoSize)
            #endif
        } else if event.reply_userdata == 2 {
            renderSize.height = CGFloat(min(value, 720))
            #if canImport(OpenGLES)
            glVideoSize.height = CGFloat(min(value, 1080))
            glRenderer?.resize(to: glVideoSize)
            #endif
        }
    }
}

/// Two-slot frame buffer pool for the software renderer.
/// renderFrame renders into the idle slot and hands that slot's
/// memory to the CGImage with no copy; the slot comes back when the
/// image's provider is released. All state is behind one lock: the
/// render thread acquires, the provider release callback (any
/// thread) releases, the event loop tears down. @unchecked Sendable:
/// every access goes through the lock.
private final class FrameBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [UnsafeMutableRawPointer?] = [nil, nil]
    private var sizes: [Int] = [0, 0]
    private var inUse: [Bool] = [false, false]
    private var dead = false

    /// The idle slot's buffer, grown to at least `size`, marked in
    /// use. Nil when both slots are still on screen (the caller
    /// skips the frame instead of blocking).
    func acquire(size: Int) -> (index: Int, ptr: UnsafeMutableRawPointer)? {
        lock.lock()
        defer { lock.unlock() }
        guard !dead else { return nil }
        for i in 0..<2 where !inUse[i] {
            if sizes[i] < size {
                slots[i]?.deallocate()
                slots[i] = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
                sizes[i] = size
            }
            inUse[i] = true
            return (i, slots[i]!)
        }
        return nil
    }

    /// Return a slot. After teardown the slot's memory is freed
    /// here instead — the provider may outlive the engine.
    func release(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard (0..<2).contains(index) else { return }
        if dead {
            slots[index]?.deallocate()
            slots[index] = nil
            sizes[index] = 0
        }
        inUse[index] = false
    }

    /// Engine teardown: idle slots are freed now; slots still on
    /// screen are freed by their release callbacks.
    func teardown() {
        lock.lock()
        defer { lock.unlock() }
        dead = true
        for i in 0..<2 where !inUse[i] {
            slots[i]?.deallocate()
            slots[i] = nil
            sizes[i] = 0
        }
    }
}

/// What a CGDataProvider's dataInfo carries: the pool plus the slot
/// index, so the release callback can return the slot. Retained by
/// the provider (+1) and taken back in the callback.
private final class FrameProviderContext {
    let pool: FrameBufferPool
    let index: Int

    init(pool: FrameBufferPool, index: Int) {
        self.pool = pool
        self.index = index
    }

    func release() {
        pool.release(index: index)
    }
}

/// The view mpv renders into: layer.contents is the latest frame,
/// aspect-fit by the layer. Plain UIKit — no libmpv dependency
/// beyond the engine that feeds it.
private final class MpvVideoView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ image: CGImage) {
        layer.contents = image
    }

    func setFill(_ fill: Bool) {
        layer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

#endif
