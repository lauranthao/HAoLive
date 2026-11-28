// MpvGLRenderer.swift
// HAo Live — GPU render path for mpv on iOS (media_kit's TextureHW,
// ported to UIKit; Pure Live's player renders exactly this way).
//
// WHY: the software renderer rasterises every pixel on the CPU and
// uploads the frame to the GPU each time — that is the build 8/9 lag
// on FLV rooms (Douyu is FLV-only, Douyin picks FLV first, Huya
// picks FLV first). Pure Live / media_kit never touch the CPU with
// a frame: VideoToolbox decodes to GPU surfaces, mpv's OpenGL
// renderer draws into an FBO texture, and the texture reaches the
// screen as a CVPixelBuffer — zero CPU copies.
//
// HOW (media_kit_video/ios/.../plugin/TextureHW.swift,
// TextureGLESContext.swift, OpenGLESHelpers.swift, VideoOutput.swift):
//   * EAGLContext (OpenGL ES 3) + CVOpenGLESTextureCache.
//   * mpv render context with MPV_RENDER_API_TYPE_OPENGL and a
//     get_proc_address that resolves GL symbols from the
//     com.apple.opengles bundle.
//   * Three FBO slots, each a CVPixelBuffer + GL texture +
//     framebuffer (media_kit's SwappableObjectManager, triple
//     buffered). mpv renders into the slot's FBO; the slot's
//     CVPixelBuffer is wrapped in a CMSampleBuffer and enqueued to
//     an AVSampleBufferDisplayLayer, which does aspect-fit/fill
//     (videoGravity) and displays it — the layer owns the timing,
//     expectsMediaDataInRealTime drops stale frames for live.
//   * Size comes from mpv's dwidth/dheight (the engine observes
//     them), capped at 1920x1080 — the GPU scales, the CPU does not.
//   * Simulator: media_kit disables hardware rendering there ("an
//     incompatibility with OpenGL ES") and uses the software
//     renderer. HAoLive does the same: this renderer is only
//     constructed on device; the engine keeps the SW path as the
//     fallback when EAGLContext creation fails or the SDK lacks
//     OpenGLES (canImport gate).
//
// THREADING: all GL work runs on one dedicated serial queue; the
// mpv update callback only signals it (coalesced). The renderer
// enqueues sample buffers to the display layer directly from that
// queue — AVSampleBufferDisplayLayer is fed from decode threads by
// design — so no CMSampleBuffer ever crosses a Swift isolation
// boundary. The only hop out is the void first-frame callback.

#if canImport(Libmpv) && canImport(OpenGLES)
import Libmpv
import OpenGLES
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import UIKit

/// One render slot: a CVPixelBuffer + the GL texture + FBO bound to it.
private final class GLFrameSlot {
    let pixelBuffer: CVPixelBuffer
    let texture: CVOpenGLESTexture
    let framebuffer: GLuint
    let size: CGSize

    init?(context: EAGLContext, cache: CVOpenGLESTextureCache, size: CGSize) {
        self.size = size
        // CVPixelBufferCreate with the same attributes media_kit
        // uses (32BGRA, Metal-compatible) plus an explicit
        // IOSurface backing so the display layer takes it zero-copy.
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        ) == kCVReturnSuccess, let pb else { return nil }
        self.pixelBuffer = pb

        var tex: CVOpenGLESTexture?
        guard CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pb,
            nil,
            GLenum(GL_TEXTURE_2D),
            GL_RGBA,
            GLsizei(size.width),
            GLsizei(size.height),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_BYTE),
            0,
            &tex
        ) == kCVReturnSuccess, let tex else { return nil }
        self.texture = tex

        // media_kit retries the FBO up to 4 times: a freshly made
        // pixel buffer sometimes yields GL_FRAMEBUFFER_INCOMPLETE_
        // ATTACHMENT on the first attempt.
        var fbo: GLuint = 0
        var ok = false
        for _ in 0...3 {
            EAGLContext.setCurrent(context)
            // media_kit's createFrameBuffer binds the texture before
            // attaching it to the FBO.
            glBindTexture(GLenum(GL_TEXTURE_2D), CVOpenGLESTextureGetName(tex))
            var candidate: GLuint = 0
            glGenFramebuffers(1, &candidate)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), candidate)
            glFramebufferTexture2D(
                GLenum(GL_FRAMEBUFFER),
                GLenum(GL_COLOR_ATTACHMENT0),
                GLenum(GL_TEXTURE_2D),
                CVOpenGLESTextureGetName(tex),
                0
            )
            let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            if status == GLenum(GL_FRAMEBUFFER_COMPLETE) {
                fbo = candidate
                ok = true
                EAGLContext.setCurrent(nil)
                break
            }
            // Delete while the context is still current — after
            // setCurrent(nil) the delete would be a no-op.
            glDeleteFramebuffers(1, &candidate)
            EAGLContext.setCurrent(nil)
        }
        guard ok else { return nil }
        self.framebuffer = fbo
    }

    /// GL teardown for one slot. Runs on the GL queue.
    func dispose(context: EAGLContext) {
        EAGLContext.setCurrent(context)
        var fbo = framebuffer
        glDeleteFramebuffers(1, &fbo)
        var name = CVOpenGLESTextureGetName(texture)
        glDeleteTextures(1, &name)
        EAGLContext.setCurrent(nil)
        // The pixel buffer + texture objects are ARC/CF-managed.
    }
}

/// The GPU renderer. Created by MpvPlayerEngine on device when
/// EAGL is available; nil when it is not (simulator / EAGL failure)
/// — the engine then uses the software renderer.
///
/// BUILD 11 — the failure used to be silent: init returned nil
/// with no log and no reason anywhere, so a phone that cannot
/// build EAGL fell back to the software renderer unnoticed — the
/// likely cause of 原画 lag on all platforms (chen 2026-11-28:
/// every platform lags at 原画). Every failure point now records
/// its reason (lastFailureReason + os log) so the engine can say
/// which path is active, and a dead slot pool reports through
/// onStalled instead of sitting on a permanent black screen.
final class MpvGLRenderer {
    /// Last GL construction / slot failure, for diagnostics.
    /// Lock-guarded: written from init (main) and the GL queue.
    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var _lastFailureReason: String?
    static var lastFailureReason: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _lastFailureReason
    }

    static func recordFailure(_ reason: String) {
        failureLock.lock()
        _lastFailureReason = reason
        failureLock.unlock()
        Logger(subsystem: "live.haostudio", category: "gl").error("GL renderer failed: \(reason, privacy: .public)")
    }

    /// Failable: nil when no EAGL context can be made.
    init?(handle: OpaquePointer, displayLayer: AVSampleBufferDisplayLayer, onFirstFrame: @escaping () -> Void) {
        guard let context = EAGLContext(api: .openGLES3) else {
            Self.recordFailure("EAGLContext(OpenGL ES 3) 创建失败")
            return nil
        }
        self.context = context
        self.handle = handle
        self.displayLayer = displayLayer
        self.onFirstFrame = onFirstFrame
        var cache: CVOpenGLESTextureCache?
        guard CVOpenGLESTextureCacheCreate(
            kCFAllocatorDefault, nil, context, nil, &cache
        ) == kCVReturnSuccess, let cache else {
            Self.recordFailure("CVOpenGLESTextureCache 创建失败")
            return nil
        }
        self.textureCache = cache
        guard createRenderContext() else { return nil }
    }

    private let handle: OpaquePointer
    private let context: EAGLContext
    private let textureCache: CVOpenGLESTextureCache
    private let onFirstFrame: () -> Void
    /// Set once at init (main thread), read on the GL queue, nilled
    /// only after teardown. Strong is safe: the layer does not
    /// reference the renderer back (no cycle). Enqueue is designed
    /// to be called off the main thread.
    private nonisolated(unsafe) var displayLayer: AVSampleBufferDisplayLayer?
    private nonisolated(unsafe) var renderContext: OpaquePointer?
    private nonisolated(unsafe) var renderCallbackToken: UnsafeMutableRawPointer?
    private let glQueue = DispatchQueue(label: "live.mpv.gl", qos: .userInitiated)
    private nonisolated(unsafe) var renderPending = false
    private nonisolated(unsafe) var slots: [GLFrameSlot] = []
    private nonisolated(unsafe) var slotIndex = 0
    private nonisolated(unsafe) var videoSize: CGSize = .zero
    private nonisolated(unsafe) var formatDescription: CMVideoFormatDescription?
    private nonisolated(unsafe) var formatSize: CGSize = .zero
    private nonisolated(unsafe) var lastPTS: CMTime = .invalid
    private nonisolated(unsafe) var firstFrameReported = false
    private nonisolated(unsafe) var tornDown = false
    /// Fired once (GL queue) when the renderer is permanently
    /// black: video size known, render context live, but no FBO
    /// slots. The engine fails the attempt so the service sweeps
    /// on instead of sitting on a black screen until the watchdog.
    nonisolated(unsafe) var onStalled: (() -> Void)?
    private nonisolated(unsafe) var stallReported = false

    /// Cap: the GPU renders at native video size up to 1080p; the
    /// CPU never sees these pixels either way.
    static let maxDimension: CGFloat = 1920
    static let maxHeight: CGFloat = 1080

    deinit {
        teardown()
    }

    // MARK: - mpv render context (OpenGL)

    /// Runs on the calling thread (init, main): creates the mpv
    /// render context with the OpenGL API. The get_proc_address
    /// callback resolves GL symbols from the com.apple.opengles
    /// bundle, exactly as media_kit's TextureHW does.
    private func createRenderContext() -> Bool {
        // media_kit's TextureHW.initMPV makes the EAGL context
        // current before mpv_render_context_create: libmpv resolves
        // GL entry points against the current context, and without
        // one the create call fails on device (build 12 tag
        // "GL失败： mpv_render_context_create 失败…") so every room
        // falls back to the SW renderer — the "卡爆了".
        EAGLContext.setCurrent(context)
        defer { EAGLContext.setCurrent(nil) }
        // The get_proc_address closure cannot capture (it becomes a
        // C function pointer), so the bundle check happens up front
        // instead of inside it — a missing bundle used to fail
        // silently here with no reason recorded.
        guard CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString) != nil else {
            Self.recordFailure("com.apple.opengles bundle 未找到（GL 符号解析失败）")
            return false
        }
        var procAddress = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                // CFStringCreateWithCString returns a non-optional
                // CFString (media_kit assigns it directly); only the
                // bundle lookup is optional.
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
                guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString) else { return nil }
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )
        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var params: [mpv_render_param] = withUnsafeMutableBytes(of: &procAddress) { proc in
            [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: proc.baseAddress.map { UnsafeMutableRawPointer($0) }),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
        }
        var created: OpaquePointer?
        let result = params.withUnsafeMutableBufferPointer { buffer in
            mpv_render_context_create(&created, handle, buffer.baseAddress)
        }
        guard result == 0, let created else {
            Self.recordFailure("mpv_render_context_create 失败（code \(result)）")
            return false
        }
        renderContext = created
        // passRetained: the callback borrows (takeUnretainedValue);
        // released in teardown after the context is freed.
        let token = Unmanaged.passRetained(self).toOpaque()
        renderCallbackToken = token
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<MpvGLRenderer>.fromOpaque(raw).takeUnretainedValue().renderUpdateRequested()
        }
        mpv_render_context_set_update_callback(created, callback, token)
        return true
    }

    // MARK: - Render (GL queue)

    /// Called from libmpv's render thread. Coalesced: one pending
    /// render at a time (a torn read only costs one extra frame).
    func renderUpdateRequested() {
        guard !renderPending, !tornDown else { return }
        renderPending = true
        glQueue.async { [weak self] in self?.renderFrame() }
    }

    /// New video size from the engine (dwidth/dheight). Recreates
    /// the slots on the GL queue; a zero size disables rendering.
    func resize(to size: CGSize) {
        let capped = CGSize(
            width: min(max(size.width, 0), Self.maxDimension),
            height: min(max(size.height, 0), Self.maxHeight)
        )
        glQueue.async { [weak self] in
            guard let self, !self.tornDown else { return }
            guard capped != self.videoSize else { return }
            self.videoSize = capped
            self.recreateSlots()
        }
    }

    private func recreateSlots() {
        for slot in slots { slot.dispose(context: context) }
        slots = []
        slotIndex = 0
        formatDescription = nil
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        for _ in 0..<3 {
            guard let slot = GLFrameSlot(context: context, cache: textureCache, size: videoSize) else { break }
            slots.append(slot)
        }
        if slots.isEmpty {
            // Every slot failed: the next renderFrame would return
            // forever (permanent black screen). Record it here; the
            // stall report in renderFrame triggers the failover.
            Self.recordFailure("recreateSlots 未建成任何 FBO（\(Int(videoSize.width))×\(Int(videoSize.height))）")
        }
    }

    /// Runs on the GL queue. Renders one frame into the next slot's
    /// FBO and enqueues its pixel buffer to the display layer.
    private func renderFrame() {
        defer { renderPending = false }
        guard !tornDown, let renderCtx = renderContext else { return }
        guard !slots.isEmpty else {
            // Video size known but no slots: the GPU path is dead.
            // Report once so the engine fails over; without this
            // every frame returned here and the room sat black
            // until the watchdog fired on the same broken engine.
            if videoSize.width > 0, videoSize.height > 0, !stallReported {
                stallReported = true
                onStalled?()
            }
            return
        }
        let slot = slots[slotIndex]
        slotIndex = (slotIndex + 1) % slots.count

        EAGLContext.setCurrent(self.context)
        defer {
            if glGetError() != GLenum(GL_NO_ERROR) { /* logged by mpv's own GL checks; keep rendering */ }
            EAGLContext.setCurrent(nil)
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), slot.framebuffer)
        defer { glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0) }
        var fbo = mpv_opengl_fbo(
            fbo: Int32(slot.framebuffer),
            w: Int32(videoSize.width),
            h: Int32(videoSize.height),
            internal_format: 0
        )
        let result: Int32 = withUnsafeMutablePointer(to: &fbo) { fboPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return params.withUnsafeMutableBufferPointer { buffer in
                mpv_render_context_render(renderCtx, buffer.baseAddress)
            }
        }
        glFlush()
        guard result == 0 else { return }
        enqueue(slot: slot)
    }

    /// Wrap the slot's pixel buffer in a CMSampleBuffer and enqueue
    /// it. Runs on the GL queue; the layer takes the buffer from
    /// here. PTS is the monotonic system uptime, kept increasing.
    private func enqueue(slot: GLFrameSlot) {
        guard let layer = displayLayer else { return }
        if formatDescription == nil || formatSize != slot.size {
            var desc: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: slot.pixelBuffer,
                formatDescriptionOut: &desc
            ) == noErr, let desc else { return }
            formatDescription = desc
            formatSize = slot.size
        }
        guard let desc = formatDescription else { return }
        var pts = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000)
        if lastPTS.isValid, pts <= lastPTS {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1_000_000))
        }
        lastPTS = pts
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: slot.pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        // Latest frame wins (build 16 — the Pure Live read): media_kit's
        // iOS path never queues frames for display. Its texture holds
        // only the newest rendered frame (SwappableObjectManager's
        // current) and Flutter's engine samples it at the next vsync,
        // so frames rendered between vsyncs are silently skipped.
        // HAoLive used to enqueue EVERY rendered frame with PTS=now,
        // so after any uneven production (network catch-up, audio
        // clock correction, a slow render) the layer had to play a
        // burst of near-identical-PTS frames in sequence, then a
        // gap — "two frames at once, then a stall". flush() drops
        // the not-yet-displayed frame(s) so only the newest remains
        // queued, the same latest-wins presentation; the currently
        // displayed frame is untouched. PTS stays "now": with one
        // pending frame it displays at the next vsync.
        layer.flush()
        layer.enqueue(sampleBuffer)
        if !firstFrameReported {
            firstFrameReported = true
            onFirstFrame()
        }
    }

    // MARK: - Teardown

    /// Frees the render context (unregisters the callback first),
    /// then the slots. Safe to call twice; deinit calls it too.
    /// Runs synchronously on the GL queue so no render is in
    /// flight when the context dies.
    func teardown() {
        glQueue.sync { [self] in
            guard !tornDown else { return }
            tornDown = true
            // media_kit's TextureHW.disposeMPV: the EAGL context
            // must be current while the render context is freed.
            EAGLContext.setCurrent(self.context)
            defer { EAGLContext.setCurrent(nil) }
            if let context = renderContext {
                mpv_render_context_set_update_callback(context, nil, nil)
                mpv_render_context_free(context)
                renderContext = nil
            }
            if let token = renderCallbackToken {
                renderCallbackToken = nil
                Unmanaged<MpvGLRenderer>.fromOpaque(token).release()
            }
            for slot in slots { slot.dispose(context: self.context) }
            slots = []
            formatDescription = nil
            displayLayer = nil
            // media_kit's deleteTextureCache: flush so the cache
            // releases its IOSurface references.
            CVOpenGLESTextureCacheFlush(textureCache, 0)
        }
    }
}

/// The view the GPU renderer draws into: an
/// AVSampleBufferDisplayLayer host. The engine swaps this in for
/// the SW view when the GL renderer is active.
final class MpvGLVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        // NOTE: expectsMediaDataInRealTime lives on
        // AVSampleBufferRenderSynchronizer, not on the layer — the
        // layer drops late frames on its own when fed real-time
        // timestamps, so there is nothing to set here.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The layer the renderer enqueues into.
    var sampleLayer: AVSampleBufferDisplayLayer { displayLayer }

    func setFill(_ fill: Bool) {
        displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    /// Clear the last frame (stop / engine swap).
    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}

#endif
