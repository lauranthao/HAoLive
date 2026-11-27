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
// RENDERING: libmpv exposes no Metal render API — render.h defines
// only MPV_RENDER_API_TYPE_OPENGL and a software renderer. OpenGL ES
// is deprecated since iOS 12, has no headers in the iOS 26 SDK and
// crashes on Apple Silicon simulators, so this engine uses the
// SOFTWARE renderer (MPV_RENDER_API_TYPE_SW), the same fallback
// media_kit forces on iOS simulators: frames are rendered into a
// CPU buffer and displayed as a CGImage. It costs CPU (not GPU);
// the OpenGL/EAGL path is the performance upgrade if the SDK
// headers allow it on the build stack, not a correctness fix.
//
// OPTIONS: Pure Live's MediaKitLiveProperties table, translated:
// protocol whitelist, 2 MB probe, 2 s analyze, 15 s network
// timeout, hwdec auto + software fallback, 30 s cache, 96 MB
// demuxer cap (40 MB on <=4-core devices), 8 s readahead,
// decoder+vo framedrop; low-end devices add the reconnect /
// lowres / skiploopfilter set. Per source: http-header-fields
// (the playback headers), demuxer-lavf-format 'hls' for HLS,
// force-seekable no, cache-pause no (live).

#if canImport(Libmpv)
import Libmpv
import CoreGraphics
import Foundation
import UIKit

final class MpvPlayerEngine: PlayerEngine {
    let name = "mpv"

    weak var delegate: (any PlayerEngineDelegate)?

    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var eventThread: Thread?
    private var destroying = false
    private var opened = false
    private var paused = false
    private var firstFrameReported = false
    private var renderPending = false
    private var renderSize = CGSize(width: 1280, height: 720)
    private var frameBuffer: UnsafeMutableRawPointer?
    private var frameBufferSize = 0

    private let videoViewInstance = MpvVideoView()
    var videoView: UIView { videoViewInstance }

    var isPlaying: Bool { opened && !paused }

    /// False when mpv_create / mpv_initialize failed — the service
    /// skips an unusable engine instead of sweeping into it.
    var isAvailable: Bool { handle != nil }

    func canPlay(_ stream: PlayStream) -> Bool {
        // mpv plays everything we offer (FLV / HLS / RTMP / mp4).
        true
    }

    // MARK: - Lifecycle

    init() {
        guard let handle = mpv_create() else { return }
        self.handle = handle
        applyOptions(handle)
        guard mpv_initialize(handle) == 0 else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            return
        }
        createRenderContext(handle)
        startEventThread()
    }

    /// Tear the mpv instance down. The service calls this from stop()
    /// and drops the engine afterwards — a destroyed engine is never
    /// re-opened; the service creates a fresh one on the next open().
    /// The event thread owns the final free, so this only signals.
    func destroy() {
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
            delegate?.engine(self, didFailWith: "mpv 未能初始化")
            return
        }
        opened = false
        paused = false
        firstFrameReported = false
        // Per-source properties (Pure Live's per-source table).
        setOption(handle, "http-proxy", "")
        setOption(handle, "demuxer-lavf-format", format == "hls" ? "hls" : "")
        setOption(handle, "force-seekable", "no")
        setOption(handle, "cache-pause", "no")
        if !headers.isEmpty {
            // "Field: value, Field: value" — our headers carry no commas.
            let fields = headers
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            setOption(handle, "http-header-fields", fields)
            if let userAgent = headers["User-Agent"] {
                setOption(handle, "user-agent", userAgent)
            }
        }
        var args: [UnsafeMutablePointer<CChar>?] = [
            strdup("loadfile"), strdup(url.absoluteString), strdup("replace"), nil,
        ]
        defer { args.forEach { if let p = $0 { free(p) } } }
        let result = args.withUnsafeBufferPointer { buffer in
            mpv_command(handle, UnsafeMutablePointer(mutating: buffer.baseAddress))
        }
        if result < 0 {
            delegate?.engine(self, didFailWith: errorMessage(result))
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
        mpv_command_string(handle, "stop")
    }

    func setVideoFit(fill: Bool) {
        videoViewInstance.setFill(fill)
    }

    // MARK: - Options (Pure Live's MediaKitLiveProperties table)

    private func applyOptions(_ handle: OpaquePointer) {
        let lowEnd = ProcessInfo.processInfo.processorCount <= 4
        setOption(handle, "vo", "libmpv")
        setOption(handle, "ao", "audiounit")
        setOption(handle, "hwdec", "auto")
        setOption(handle, "hwdec-software-fallback", "1")
        setOption(handle, "protocol-whitelist", "httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt")
        setOption(handle, "demuxer-lavf-probesize", "2097152")
        setOption(handle, "demuxer-lavf-analyzeduration", "2")
        setOption(handle, "network-timeout", "15")
        setOption(handle, "cache", "yes")
        setOption(handle, "cache-on-disk", "no")
        setOption(handle, "cache-secs", "30")
        setOption(handle, "demuxer-max-bytes", lowEnd ? "41943040" : "100663296")
        setOption(handle, "demuxer-max-back-bytes", lowEnd ? "5242880" : "8388608")
        setOption(handle, "demuxer-donate-buffer", "no")
        setOption(handle, "demuxer-readahead-secs", "8")
        setOption(handle, "cache-pause-wait", "4")
        setOption(handle, "demuxer-thread", "yes")
        setOption(handle, "framedrop", "decoder+vo")
        // Volume is the system slider's job on iOS (Pure Live sets an
        // internal gain of 1.0 on iOS/Android); keep mpv at full gain.
        setOption(handle, "volume", "100")
        if lowEnd {
            setOption(handle, "audio-buffer", "0.4")
            setOption(handle, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2")
            setOption(handle, "vd-lavc-threads", "2")
            setOption(handle, "vd-lavc-o", "lowres=1")
            setOption(handle, "vd-lavc-skiploopfilter", "nonref")
        } else {
            setOption(handle, "vd-lavc-o", "lowres=0")
        }
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

    private func setPropertyFlag(_ handle: OpaquePointer, _ name: String, _ value: Bool) {
        name.withCString { namePtr in
            var flag: Int64 = value ? 1 : 0
            _ = mpv_set_property(handle, namePtr, mpv_format.flag, &flag)
        }
    }

    private func errorMessage(_ code: Int32) -> String {
        guard let cString = mpv_error_string(code) else { return "播放失败" }
        return String(cString: cString)
    }

    // MARK: - Render context (software renderer)

    private func createRenderContext(_ handle: OpaquePointer) {
        "sw".withCString { apiPtr in
            var params = [
                mpv_render_param(type: mpv_render_param_type.apiType, data: UnsafeMutableRawPointer(mutating: apiPtr)),
                mpv_render_param(type: mpv_render_param_type.invalid, data: nil),
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
            mpv_render_context_set_update_callback(context, callback, Unmanaged.passUnretained(self).toOpaque())
        }
        observeVideoSize(handle)
    }

    private func observeVideoSize(_ handle: OpaquePointer) {
        // dwidth/dheight drive the render buffer size.
        "dwidth".withCString { name in
            _ = mpv_observe_property(handle, 1, name, mpv_format.int64)
        }
        "dheight".withCString { name in
            _ = mpv_observe_property(handle, 2, name, mpv_format.int64)
        }
    }

    /// Called on libmpv's render thread when a new frame is available.
    private func renderUpdateRequested() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.renderFrame()
        }
    }

    private func renderFrame() {
        defer { renderPending = false }
        guard let context = renderContext else { return }
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        guard width > 0, height > 0 else { return }
        let stride = width * 4
        let size = stride * height
        if frameBuffer == nil || frameBufferSize < size {
            frameBuffer?.deallocate()
            frameBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            frameBufferSize = size
        }
        guard let buffer = frameBuffer else { return }
        var swSize: [Int32] = [Int32(width), Int32(height)]
        var strideValue: Int = stride
        var pointer: UnsafeMutableRawPointer? = buffer
        // NOTE: the frame is copied into a Data below (one memcpy per
        // frame) because the render buffer is reused for the next
        // frame — handing the live buffer to the CGImage would tear.
        let image: CGImage? = "rgba".withCString { formatPtr in
            swSize.withUnsafeMutableBufferPointer { sizePtr in
                var params = [
                    mpv_render_param(type: mpv_render_param_type.swSize, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                    mpv_render_param(type: mpv_render_param_type.swFormat, data: UnsafeMutableRawPointer(mutating: formatPtr)),
                    mpv_render_param(type: mpv_render_param_type.swStride, data: UnsafeMutableRawPointer(&strideValue)),
                    mpv_render_param(type: mpv_render_param_type.swPointer, data: UnsafeMutableRawPointer(&pointer)),
                    mpv_render_param(type: mpv_render_param_type.invalid, data: nil),
                ]
                let result = params.withUnsafeMutableBufferPointer { buffer in
                    mpv_render_context_render(context, buffer.baseAddress)
                }
                guard result == 0 else { return nil }
                // rgba in memory = R,G,B,A per pixel; the video is opaque.
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                guard let dataProvider = CGDataProvider(data: Data(bytes: buffer, count: size) as CFData) else { return nil }
                return CGImage(
                    width: width, height: height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                    space: colorSpace, bitmapInfo: bitmapInfo,
                    provider: dataProvider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent
                )
            }
        }
        guard let image else { return }
        let isFirst = !firstFrameReported
        if isFirst { firstFrameReported = true }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.videoViewInstance.display(image)
            if isFirst {
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

    private func eventLoop() {
        guard let handle else { return }
        while !destroying {
            guard let event = mpv_wait_event(handle, 1.0) else { continue }
            switch event.pointee.event_id {
            case mpv_event_id.shutdown:
                destroying = true
            case mpv_event_id.endFile:
                handleEndFile(event.pointee)
            case mpv_event_id.videoReconfig:
                renderUpdateRequested()
            case mpv_event_id.propertyChange:
                handlePropertyChange(event.pointee)
            default:
                break
            }
        }
        // The thread owns the final teardown: render context first,
        // then the handle, then the frame buffer.
        if let context = renderContext {
            mpv_render_context_free(context)
            renderContext = nil
        }
        mpv_terminate_destroy(handle)
        self.handle = nil
        frameBuffer?.deallocate()
        frameBuffer = nil
        frameBufferSize = 0
    }

    private func handleEndFile(_ event: mpv_event) {
        // A live stream ending (EOF) or erroring is a hard failure —
        // the sweep advances to the next candidate.
        guard opened, let data = event.data else { return }
        let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        switch endFile.reason {
        case mpv_end_file_reason.error:
            let message = endFile.error != 0 ? errorMessage(endFile.error) : "播放失败"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didFailWith: message)
            }
        case mpv_end_file_reason.eof:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didFailWith: "直播流已结束")
            }
        default:
            break
        }
    }

    private func handlePropertyChange(_ event: mpv_event) {
        guard let data = event.data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard property.format == mpv_format.int64, let valuePtr = property.data else { return }
        let value = valuePtr.assumingMemoryBound(to: Int64.self).pointee
        guard value > 0 else { return }
        if property.reply_userdata == 1 {
            renderSize.width = CGFloat(min(value, 1920))
        } else if property.reply_userdata == 2 {
            renderSize.height = CGFloat(min(value, 1080))
        }
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
