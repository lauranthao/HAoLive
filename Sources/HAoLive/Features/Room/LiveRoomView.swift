// LiveRoomView.swift
// HAo Live — live room page, Pure Live's LivePlayPage layout,
// translated to SwiftUI (rewrite in Swift, same as the routes).
//
// Normal room (portrait entry): header (avatar + anchor + platform
// / area | favorite, menu) -> 16:9 video with overlay controls ->
// resolutions row (audience | quality | line) -> danmaku panel
// with four tabs (弹幕列表 / Super Chat / 弹幕设置 / 屏蔽列表).
// Fullscreen keeps the same overlay controls on a black canvas,
// with a local danmaku composer in the middle of the bottom bar.
// Entering a room records history.
//
// Controls (Pure Live's VideoControllerPanel): bars are 56 pt,
// gradient black45, slide in/out over 300 ms, auto-hide after 5 s
// while playing (never hidden while paused / loading / failed).
// Tap toggles the bars (a tap on a paused surface also resumes);
// double-tap toggles fullscreen (unless locked); vertical drag on
// the left half changes brightness, on the right half volume, both
// showing the same centre card. The lock button hides the bars and
// all gestures except tap-to-unlock.
//
// Brightness/volume live only in the player: the brightness at entry
// is restored when the room closes, so the app never overrides the
// user's system brightness. Volume goes through the system volume
// (MPVolumeView), never an in-engine gain.

import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct LiveRoomView: View {
    let room: LiveRoom

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @StateObject private var playerService = LivePlayerService()
    @State private var streams: [PlayStream] = []
    @State private var showingQualityPicker = false
    @State private var showingDanmakuSettings = false
    @State private var isFullscreen = false
    @State private var danmakuEngine = DanmakuEngine()
    @State private var visibleDanmaku: [DanmakuItem] = []
    @State private var loadError: String?
    @State private var danmakuTask: Task<Void, Never>?

    /// The site that opened this room's streams, so the room's
    /// held playback session (niconico seat / FC2 control) can
    /// be closed when the room closes.
    @State private var playbackSite: (any LiveSite)?

    /// Room as re-fetched from the platform (title / host / viewers /
    /// live status); the list copy is the fallback when it fails.
    @State private var detailRoom: LiveRoom?

    /// The room as shown: detail when available, else the list copy.
    private var displayRoom: LiveRoom { detailRoom ?? room }

    // Sleep timer (Pure Live's room timer: pauses on fire, never
    // closes the page).
    @State private var showingSleepTimer = false
    @State private var sleepMinutes: Int?
    @State private var sleepTask: Task<Void, Never>?
    @State private var showSleepDone = false
    @State private var composerText = ""

    // Player chrome state (Pure Live's VideoController).
    @State private var showControls = true
    @State private var locked = false
    @State private var volumeCard: (icon: String, percent: Int)?
    @State private var hideTask: Task<Void, Never>?
    @State private var volumeHideTask: Task<Void, Never>?
    @State private var videoFill = false
    @State private var brightnessAtEntry: CGFloat = 0.5
    @State private var dragStart: (x: CGFloat, brightness: CGFloat, volume: Float)?
    @State private var dragActive = false
    @State private var videoSize = CGSize.zero

    @State private var selectedDanmakuTab = 0
    @State private var newKeyword = ""

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            playerArea
            resolutionsRow
            Divider()
            danmakuPanel
            composerRow
        }
        .background(SystemVolumeView())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingQualityPicker) {
            QualityPickerView(streams: streams, selectedStream: playerService.currentStream) { stream in
                playerService.switchStream(stream)
            }
        }
        .sheet(isPresented: $showingDanmakuSettings) {
            DanmakuSettingsSheet(settingsStore: settingsStore)
        }
        .sheet(isPresented: $showingSleepTimer) {
            SleepTimerSheet(
                activeMinutes: sleepMinutes,
                onSet: { startSleepTimer(minutes: $0) },
                onCancel: { cancelSleepTimer() }
            )
        }
        .alert("睡眠定时已到", isPresented: $showSleepDone) {
            Button("好", role: .cancel) {}
        } message: {
            Text("已暂停播放")
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenPlayerView(
                playerService: playerService,
                room: displayRoom,
                danmakuItems: visibleDanmaku,
                danmakuEnabled: settingsStore.danmakuEnabled,
                danmakuFontSize: settingsStore.danmakuFontSize,
                danmakuOpacity: settingsStore.danmakuOpacity,
                danmakuSpeed: settingsStore.danmakuSpeed,
                danmakuArea: settingsStore.danmakuArea,
                danmakuFontWeight: settingsStore.danmakuFontWeight,
                danmakuLetterSpacing: settingsStore.danmakuLetterSpacing,
                danmakuStrokeEnabled: settingsStore.danmakuStrokeEnabled,
                danmakuStrokeWidth: settingsStore.danmakuStrokeWidth,
                danmakuMaxVisibleCount: settingsStore.danmakuMaxVisibleCount,
                streams: streams,
                isFavorite: favoritesStore.isFavorite(room),
                onToggleFavorite: { toggleFavorite() },
                onToggleDanmaku: { settingsStore.danmakuEnabled.toggle() },
                onOpenDanmakuSettings: { showingDanmakuSettings = true },
                onSelectQuality: { stream in playerService.switchStream(stream) },
                onSendLocalDanmaku: { text in appendDanmaku(localItem(text: text)) },
                onClose: { isFullscreen = false }
            )
        }
        .task { await enterRoom() }
        .onDisappear {
            hideTask?.cancel()
            volumeHideTask?.cancel()
            danmakuTask?.cancel()
            danmakuTask = nil
            sleepTask?.cancel()
            sleepTask = nil
            playerService.stop()
            // Close the room's held playback session (niconico
            // seat / FC2 control): the grant dies with it, so it
            // must not outlive the room.
            playbackSite?.endPlaybackSession()
            playbackSite = nil
            UIScreen.main.brightness = brightnessAtEntry
        }
    }

    /// Local danmaku composer (inline): typed messages show locally
    /// in the overlay and the list, like Pure Live's local interaction.
    private var composerRow: some View {
        HStack(spacing: 8) {
            TextField("发一条弹幕…", text: $composerText)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
            Button("发送") {
                let text = composerText.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                appendDanmaku(localItem(text: text))
                composerText = ""
            }
            .font(.subheadline.bold())
            .foregroundStyle(HaoLiveDesign.liveRed)
            .disabled(composerText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Header (Pure Live's LivePlayHeader)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            // Avatar through the cover cache (Referer/UA + retries):
            // AsyncImage sends bare requests, which several image
            // CDNs refuse.
            AvatarImage(url: displayRoom.anchorAvatarURL, size: 32, fallbackText: String(displayRoom.anchorName.prefix(1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayRoom.anchorName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text("\(displayRoom.platform.displayName)\(displayRoom.categoryName.map { " / \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: favoritesStore.isFavorite(room) ? "heart.fill" : "heart")
                    .foregroundStyle(favoritesStore.isFavorite(room) ? HaoLiveDesign.liveRed : .primary)
            }
            .buttonStyle(.pressable)
            Menu {
                if let url = roomWebURL {
                    Button("打开直播间") { UIApplication.shared.open(url) }
                    ShareLink(item: url, label: { Label("分享", systemImage: "square.and.arrow.up") })
                    Button("复制直播间链接") {
                        UIPasteboard.general.string = url.absoluteString
                        ToastCenter.shared.show("已复制直播间链接")
                    }
                }
                if let stream = playerService.currentStream {
                    Button("复制播放地址") {
                        UIPasteboard.general.string = stream.url.absoluteString
                        ToastCenter.shared.show("已复制播放地址")
                    }
                }
                // Full render-path text (the pill in the player chrome
                // truncates): GL vs SW, the GL failure reason, and the
                // decoder — the three facts the next "卡" report needs.
                if playerService.engineName != "—" {
                    Text("渲染：\(playerService.engineName)")
                }
                Button {
                    showingSleepTimer = true
                } label: {
                    Label(
                        sleepMinutes.map { "睡眠 \($0) 分钟" } ?? "睡眠定时",
                        systemImage: sleepMinutes == nil ? "moon.zzz" : "moon.zzz.fill"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .frame(height: 56)
    }

    // MARK: - Player area (16:9 + overlay controls)

    private var playerArea: some View {
        ZStack {
            PlayerContainerView(service: playerService)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
            if settingsStore.danmakuEnabled {
                DanmakuOverlayView(
                    items: visibleDanmaku,
                    fontSize: settingsStore.danmakuFontSize,
                    opacity: settingsStore.danmakuOpacity,
                    speed: settingsStore.danmakuSpeed,
                    area: settingsStore.danmakuArea,
                    fontWeight: settingsStore.danmakuFontWeight,
                    letterSpacing: settingsStore.danmakuLetterSpacing,
                    strokeEnabled: settingsStore.danmakuStrokeEnabled,
                    strokeWidth: settingsStore.danmakuStrokeWidth,
                    maxVisibleCount: settingsStore.danmakuMaxVisibleCount
                )
            }
            // Placeholders (Pure Live's livePlayPlaceholderFor):
            // loading spins, a failed load shows the error + retry.
            if playerService.state == .loading {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    if let notice = playerService.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            if let error = loadError {
                RoomPlaceholder(icon: "exclamationmark.triangle", message: error) {
                    Task { await enterRoom() }
                }
            } else if case .failed(let message) = playerService.state {
                RoomPlaceholder(icon: "exclamationmark.triangle", message: message) {
                    playerService.refresh()
                }
            }
            // Centre volume / brightness card (300 ms fade, 1 s hide).
            if let card = volumeCard {
                HStack(spacing: 8) {
                    Image(systemName: card.icon)
                    ProgressView(value: Double(card.percent) / 100.0)
                        .tint(.white)
                        .frame(width: 100)
                    Text("\(card.percent)%")
                        .font(.caption.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: HaoLiveDesign.hudCornerRadius))
            }
            // Top + bottom control bars (56 pt, gradient black45).
            if showControls && !locked {
                PlayerChromeView(
                    service: playerService,
                    title: displayRoom.title,
                    subtitle: "\(displayRoom.anchorName) · \(displayRoom.platform.displayName)",
                    isFullscreen: false,
                    isFavorite: favoritesStore.isFavorite(room),
                    danmakuEnabled: settingsStore.danmakuEnabled,
                    videoFill: videoFill,
                    qualityText: currentQualityText,
                    onBack: nil,
                    onToggleFullscreen: { isFullscreen = true },
                    onRefresh: { playerService.refresh() },
                    onToggleFavorite: { toggleFavorite() },
                    onToggleDanmaku: { settingsStore.danmakuEnabled.toggle() },
                    onOpenDanmakuSettings: { showingDanmakuSettings = true },
                    onOpenQuality: { showingQualityPicker = true },
                    onToggleFit: {
                        videoFill.toggle()
                        playerService.setVideoFit(fill: videoFill)
                    },
                    onToggleLock: { locked = true }
                )
            }
            // Lock button (right edge, vertically centred, while the
            // bars are up).
            if showControls && !locked {
                HStack {
                    Spacer()
                    Button { locked = true } label: {
                        Image(systemName: "lock.open")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .padding(.trailing, 8)
            }
            // Locked: tap anywhere shows the unlock button.
            if locked {
                Button { locked = false } label: {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.black.opacity(0.6), in: Circle())
                }
            }
            // Persistent diagnostics pill (build 17): the tag used
            // to live in the chrome's bottom bar, so it vanished
            // with the auto-hiding chrome and was truncated to
            // 140 pt — chen's "没有tag". It now sits on the video
            // itself, always visible, full text, never intercepting
            // touches. Same pill inline and fullscreen.
            VStack {
                DiagnosticTagPill(engineName: playerService.engineName)
                    .padding(.top, 64)
                    .padding(.leading, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { videoSize = $0 }
        .onTapGesture(count: 1) { handleVideoTap() }
        .onTapGesture(count: 2) {
            guard !locked else { return }
            isFullscreen = true
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in handleVideoDragChanged(value) }
                .onEnded { _ in handleVideoDragEnded() }
        )
    }

    // MARK: - Resolutions row (Pure Live's ResolutionsRow, 56 pt)

    private var resolutionsRow: some View {
        HStack {
            Label(displayRoom.viewerCountText, systemImage: "eye.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(currentQualityText) { showingQualityPicker = true }
                .font(.subheadline)
                .disabled(streams.isEmpty)
            Button(playerService.currentStream?.line ?? "线路") { showingQualityPicker = true }
                .font(.subheadline)
                .disabled(streams.isEmpty)
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding + 4)
        .frame(height: 56)
    }

    // MARK: - Danmaku panel (Pure Live's DanmakuTabView)

    private var danmakuPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(["弹幕列表", "Super Chat", "弹幕设置", "屏蔽列表"].enumerated()), id: \.offset) { index, title in
                    Button(title) { selectedDanmakuTab = index }
                        .font(.subheadline)
                        .foregroundStyle(selectedDanmakuTab == index ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            if selectedDanmakuTab == index {
                                Rectangle()
                                    .fill(HaoLiveDesign.liveRed)
                                    .frame(height: 2)
                            }
                        }
                }
            }
            Divider()
            Group {
                switch selectedDanmakuTab {
                case 0:
                    danmakuListTab
                case 1:
                    ContentUnavailableView("暂无 Super Chat", systemImage: "gift", description: Text("本直播间暂无 Super Chat 消息"))
                case 2:
                    danmakuSettingsTab
                default:
                    blockListTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var danmakuListTab: some View {
        Group {
            if !settingsStore.danmakuEnabled {
                ContentUnavailableView("弹幕已关闭", systemImage: "text.bubble", description: Text("在播放器下方打开弹幕开关后，这里会显示实时弹幕"))
            } else if visibleDanmaku.isEmpty {
                ContentUnavailableView("暂无弹幕", systemImage: "text.bubble", description: Text("弹幕加载中或本直播间暂无弹幕"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(visibleDanmaku) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(item.user)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(item.text)
                                        .font(.subheadline)
                                }
                                .id(item.id)
                                .contextMenu {
                                    if item.user != "我" && !settingsStore.blockedUsers.contains(item.user) {
                                        Button("屏蔽该用户", role: .destructive) {
                                            settingsStore.blockedUsers.append(item.user)
                                            danmakuEngine = makeDanmakuEngine()
                                            ToastCenter.shared.show("已屏蔽该用户")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, HaoLiveDesign.pagePadding)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: visibleDanmaku.count) {
                        if let last = visibleDanmaku.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private var danmakuSettingsTab: some View {
        DanmakuSettingsForm(settingsStore: settingsStore)
            .scrollContentBackground(.hidden)
    }

    private var blockListTab: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("添加屏蔽关键词", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    let keyword = newKeyword.trimmingCharacters(in: .whitespaces)
                    guard !keyword.isEmpty else { return }
                    settingsStore.blockedKeywords.append(keyword)
                    danmakuEngine = makeDanmakuEngine()
                    newKeyword = ""
                }
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .padding(.vertical, 8)
            List {
                Section("屏蔽关键词") {
                    if settingsStore.blockedKeywords.isEmpty {
                        Text("无屏蔽关键词").foregroundStyle(.secondary)
                    } else {
                        ForEach(settingsStore.blockedKeywords, id: \.self) { keyword in
                            Text(keyword)
                        }
                        .onDelete { indexSet in
                            settingsStore.blockedKeywords.remove(atOffsets: indexSet)
                            danmakuEngine = makeDanmakuEngine()
                        }
                    }
                }
                Section("屏蔽用户") {
                    if settingsStore.blockedUsers.isEmpty {
                        Text("无屏蔽用户").foregroundStyle(.secondary)
                    } else {
                        ForEach(settingsStore.blockedUsers, id: \.self) { user in
                            Text(user)
                        }
                        .onDelete { indexSet in
                            settingsStore.blockedUsers.remove(atOffsets: indexSet)
                            danmakuEngine = makeDanmakuEngine()
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Gestures (Pure Live's VideoControllerPanel)

    private func handleVideoTap() {
        if dragActive { return }
        if locked { return } // locked state has its own unlock button
        if showControls && playerService.isPlaying {
            // Touch: a second tap hides visible controls.
            hideControls()
            return
        }
        showControlsTemporarily()
        if playerService.state == .paused {
            playerService.resume()
        }
    }

    private func handleVideoDragChanged(_ value: DragGesture.Value) {
        guard !locked else { return }
        if dragStart == nil {
            dragStart = (
                x: value.startLocation.x,
                brightness: UIScreen.main.brightness,
                volume: AVAudioSession.sharedInstance().outputVolume
            )
        }
        guard let start = dragStart else { return }
        if abs(value.translation.height) > 8 || abs(value.translation.width) > 8 {
            dragActive = true
        }
        guard dragActive else { return }
        // Vertical drag: left half brightness, right half volume.
        let height = videoSize.height > 0 ? videoSize.height : 1
        let delta = -value.translation.height / height
        if start.x < videoSize.width / 2 {
            let brightness = min(max(start.brightness + delta, 0), 1)
            UIScreen.main.brightness = brightness
            showVolumeCard(icon: brightness <= 0 ? "sun.min.fill" : brightness < 0.5 ? "sun.min" : "sun.max.fill", percent: Int(brightness * 100))
        } else {
            let volume = min(max(start.volume + Float(delta), 0), 1)
            SystemVolume.shared.setVolume(volume)
            showVolumeCard(icon: volume <= 0 ? "speaker.slash.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill", percent: Int(volume * 100))
        }
    }

    private func handleVideoDragEnded() {
        dragStart = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { dragActive = false }
    }

    private func showControlsTemporarily() {
        showControls = true
        scheduleHideControls()
    }

    private func hideControls() {
        hideTask?.cancel()
        hideTask = nil
        showControls = false
    }

    private func scheduleHideControls() {
        hideTask?.cancel()
        guard playerService.isPlaying else { return } // paused / loading / failed keep the bars
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    private func showVolumeCard(icon: String, percent: Int) {
        volumeCard = (icon: icon, percent: percent)
        volumeHideTask?.cancel()
        volumeHideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            volumeCard = nil
        }
    }

    // MARK: - Loading

    private var currentQualityText: String {
        if let stream = playerService.currentStream {
            return "\(stream.quality) · \(stream.line)"
        }
        return "画质"
    }

    private var roomWebURL: URL? {
        // Room page per platform, from Pure Live's *_link.dart
        // watchUrl / url helpers. Inke has no watch page keyed
        // by uid (its URL needs live_id, which the adapter does
        // not expose on the room), so it returns nil and the
        // "用浏览器打开" item stays hidden.
        switch room.platform {
        case .bilibili: URL(string: "https://live.bilibili.com/\(room.roomID)")
        case .douyu: URL(string: "https://www.douyu.com/\(room.roomID)")
        case .huya: URL(string: "https://www.huya.com/\(room.roomID)")
        case .douyin: URL(string: "https://live.douyin.com/\(room.roomID)")
        case .kuaishou: URL(string: "https://live.kuaishou.com/u/\(room.roomID)")
        case .cc: URL(string: "https://cc.163.com/\(room.roomID)/")
        case .twitch: URL(string: "https://www.twitch.tv/\(room.roomID)")
        case .soop: URL(string: "https://play.sooplive.co.kr/\(room.roomID)")
        case .yy: URL(string: "https://www.yy.com/\(room.roomID)")
        case .acfun: URL(string: "https://live.acfun.cn/live/\(room.roomID)")
        case .picarto: URL(string: "https://picarto.tv/\(room.roomID)")
        case .twitcasting: URL(string: "https://twitcasting.tv/\(room.roomID)")
        case .missevan: URL(string: "https://fm.missevan.com/live/\(room.roomID)")
        case .inke: nil
        case .kilakila: URL(string: "https://live.kilakila.cn/zhubo/\(room.roomID)")
        case .xiaohongshu: URL(string: "https://www.xiaohongshu.com/livestream/\(room.roomID)")
        case .niconico: URL(string: "https://live.nicovideo.jp/watch/\(room.roomID)")
        case .weibo: URL(string: "https://weibo.com/l/wblive/p/show/\(room.roomID)")
        case .showroom: URL(string: "https://www.showroom-live.com/room/profile?room_id=\(room.roomID)")
        case .chzzk: URL(string: "https://chzzk.naver.com/live/\(room.roomID)")
        case .liveme: URL(string: "https://www.liveme.com/livehot/streaming/\(room.roomID)")
        case .tiktok: URL(string: "https://www.tiktok.com/@\(room.roomID)/live")
        case .youtube: URL(string: "https://www.youtube.com/watch?v=\(room.roomID)")
        case .bigo: URL(string: "https://www.bigo.tv/\(room.roomID)")
        case .pandalive: URL(string: "https://www.pandalive.co.kr/live/play/\(room.roomID)")
        case .fc2live: URL(string: "https://live.fc2.com/\(room.roomID)/")
        case .steambroadcast: URL(string: "https://steamcommunity.com/broadcast/watch/\(room.roomID)")
        case .jdlive: URL(string: "https://lives.jd.com/#/\(room.roomID)")
        case .kugoulive: URL(string: "https://fanxing.kugou.com/\(room.roomID)")
        case .baidulive: URL(string: "https://live.baidu.com/m/room/\(room.roomID)")
        case .sixroom: URL(string: "https://v.6.cn/\(room.roomID)")
        case .looklive: URL(string: "https://look.163.com/live?id=\(room.roomID)")
        case .seventeenlive: URL(string: "https://17.live/en/live/\(room.roomID)")
        case .kick: URL(string: "https://kick.com/\(room.roomID)")
        }
    }

    /// Favorite toggle with feedback (HAoMusic: every toggle toasts).
    private func toggleFavorite() {
        let nowFavorite = !favoritesStore.isFavorite(room)
        favoritesStore.toggle(room)
        ToastCenter.shared.show(nowFavorite ? "已收藏" : "已取消收藏")
    }

    private func localItem(text: String) -> DanmakuItem {
        DanmakuItem(roomID: room.roomID, user: "我", text: text)
    }

    /// The engine for this room: blocklists and limits from Settings.
    private func makeDanmakuEngine() -> DanmakuEngine {
        DanmakuEngine(
            blockedKeywords: settingsStore.blockedKeywords,
            blockedUsers: Set(settingsStore.blockedUsers),
            maxOnScreen: settingsStore.danmakuMaxVisibleCount,
            collapseRepeated: settingsStore.danmakuCollapseRepeated
        )
    }

    private func enterRoom() async {
        historyStore.record(room)
        brightnessAtEntry = UIScreen.main.brightness
        danmakuTask?.cancel()
        danmakuTask = nil
        danmakuEngine = makeDanmakuEngine()
        guard let site = SiteRegistry.site(for: room.platform) else {
            loadError = "该平台暂未接入"
            return
        }
        playbackSite = site
        // Room detail in parallel with the stream fetch: title /
        // host / viewers / live status as the platform reports
        // them now. The list copy stays if the fetch fails.
        Task {
            if let detail = try? await site.roomDetail(roomID: room.roomID) {
                detailRoom = detail
            }
        }
        // Fresh signed URLs per engine in the sweep (Pure Live's
        // onEngineFallbackSources).
        playerService.sourceRefresh = {
            (try? await site.playURLs(room: room)) ?? []
        }
        do {
            streams = try await site.playURLs(room: room)
            loadError = nil
            // Pure Live applies a separate cellular default quality;
            // the hwdec mode applies when the engine is created.
            #if canImport(Libmpv)
            MpvPlayerEngine.hwdecMode = settingsStore.hwdecMode
            #endif
            let preferredQuality = NetworkTypeMonitor.shared.isCellular
                ? settingsStore.preferredQualityCellular
                : settingsStore.preferredQuality
            playerService.open(
                streams: streams,
                preferredQuality: preferredQuality.isEmpty ? nil : preferredQuality,
                preferredLine: settingsStore.preferredLine.isEmpty ? nil : settingsStore.preferredLine
            )
        } catch {
            loadError = error.localizedDescription
            playerService.open(streams: [], preferredQuality: nil, preferredLine: nil)
        }
        startDanmakuLoop(site: site)
    }

    /// Feeds live danmaku into the overlay and the list tab. When
    /// the platform's channel closes, danmaku simply stops — no
    /// canned lines are ever shown as if they were live chat.
    private func startDanmakuLoop(site: any LiveSite) {
        danmakuTask = Task { @MainActor in
            for await item in site.danmakuStream(roomID: room.roomID) {
                guard settingsStore.danmakuEnabled else { continue }
                if danmakuEngine.accept(item) {
                    appendDanmaku(item)
                }
            }
        }
    }

    private func appendDanmaku(_ item: DanmakuItem) {
        withAnimation(.easeIn(duration: 0.3)) {
            visibleDanmaku.append(item)
            if visibleDanmaku.count > 200 {
                visibleDanmaku.removeFirst(visibleDanmaku.count - 200)
            }
        }
    }

    // MARK: - Sleep timer (Pure Live's room timer)

    /// Starts a countdown; on fire it pauses the player and shows a
    /// notice — it never closes the page.
    private func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepMinutes = minutes
        sleepTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            sleepMinutes = nil
            playerService.pause()
            showSleepDone = true
        }
    }

    private func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepMinutes = nil
    }
}

// MARK: - Player container (the service's one UIView, inline or fullscreen)

/// Embeds LivePlayerService.videoContainerView. Inline and fullscreen
/// never mount it at the same time, so the same UIView moves between
/// them — exactly how the old AVPlayer VideoPlayer was swapped.
struct PlayerContainerView: UIViewRepresentable {
    let service: LivePlayerService

    func makeUIView(context: Context) -> UIView {
        service.videoContainerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Loading / failure placeholder (Pure Live's RoomLoadFailedWidget)

struct RoomPlaceholder: View {
    let icon: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("重试") { onRetry() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: HaoLiveDesign.controlCornerRadius))
    }
}

// MARK: - Danmaku settings sheet

struct DanmakuSettingsSheet: View {
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DanmakuSettingsForm(settingsStore: settingsStore)
                .navigationTitle("弹幕设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

/// The full danmaku settings set (Pure Live's
/// DanmakuSettingsController, practical subset): speed, area,
/// max visible count, collapse-repeated, font size / weight /
/// letter spacing, opacity, stroke. Used by the room tab and the
/// fullscreen sheet alike.
struct DanmakuSettingsForm: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("显示") {
                Toggle("显示弹幕", isOn: $settingsStore.danmakuEnabled)
                HStack {
                    Text("滚动速度")
                    Slider(value: $settingsStore.danmakuSpeed, in: 20...400, step: 10)
                    Text("\(Int(settingsStore.danmakuSpeed))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("显示区域")
                    Slider(value: $settingsStore.danmakuArea, in: 0.25...1.0, step: 0.05)
                    Text("\(Int(settingsStore.danmakuArea * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                Stepper("同时显示：\(settingsStore.danmakuMaxVisibleCount) 条", value: $settingsStore.danmakuMaxVisibleCount, in: 10...120, step: 2)
                Toggle("合并重复弹幕", isOn: $settingsStore.danmakuCollapseRepeated)
            }
            Section("字体") {
                Stepper("字体大小：\(Int(settingsStore.danmakuFontSize))", value: $settingsStore.danmakuFontSize, in: 10...30, step: 1)
                Picker("字重", selection: $settingsStore.danmakuFontWeight) {
                    Text("细").tag(300)
                    Text("常规").tag(500)
                    Text("粗").tag(700)
                    Text("特粗").tag(900)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("字间距")
                    Slider(value: $settingsStore.danmakuLetterSpacing, in: -2...8, step: 0.5)
                    Text(String(format: "%.1f", settingsStore.danmakuLetterSpacing))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("不透明度")
                    Slider(value: $settingsStore.danmakuOpacity, in: 0.3...1.0)
                }
            }
            Section("描边") {
                Toggle("描边", isOn: $settingsStore.danmakuStrokeEnabled)
                if settingsStore.danmakuStrokeEnabled {
                    HStack {
                        Text("描边粗细")
                        Slider(value: $settingsStore.danmakuStrokeWidth, in: 0...4, step: 0.5)
                        Text(String(format: "%.1f", settingsStore.danmakuStrokeWidth))
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Sleep timer sheet

/// Room sleep timer (Pure Live's RoomTimerDialog): presets plus a
/// custom field; on fire the room pauses, the page stays open.
struct SleepTimerSheet: View {
    var activeMinutes: Int?
    var onSet: (Int) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customMinutes = ""

    private let presets = [15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            List {
                Section("定时暂停播放") {
                    ForEach(presets, id: \.self) { minutes in
                        Button {
                            onSet(minutes)
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(minutes) 分钟")
                                Spacer()
                                if activeMinutes == minutes {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("自定义分钟数", text: $customMinutes)
                            .keyboardType(.numberPad)
                        Button("设定") {
                            if let minutes = Int(customMinutes), minutes >= 1, minutes <= 525600 {
                                onSet(minutes)
                                dismiss()
                            }
                        }
                        .disabled(Int(customMinutes) == nil)
                    }
                    if activeMinutes != nil {
                        Button("取消定时", role: .destructive) {
                            onCancel()
                            dismiss()
                        }
                    }
                }
                Section {
                    Text("到时自动暂停播放，不关闭页面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("睡眠定时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - System volume (MPVolumeView slider trick)

/// The system volume, driven through a hidden MPVolumeView — the
/// standard iOS way to set it programmatically. The view must live
/// in a hierarchy; PlayerContainerView's parent hosts it via
/// SystemVolumeView below.
@MainActor final class SystemVolume {
    static let shared = SystemVolume()
    private let volumeView = MPVolumeView(frame: .zero)

    var view: MPVolumeView { volumeView }

    func setVolume(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

/// Hosts the shared hidden MPVolumeView (1×1, invisible).
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = SystemVolume.shared.view
        view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.alpha = 0.01
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Player chrome (Pure Live's VideoControllerPanel)

/// Top + bottom control bars over the video: 56 pt, gradient
/// black45, slide in/out over 300 ms. Top: title + subtitle
/// (fullscreen adds the clock + battery). Bottom left: play/pause,
/// refresh, favorite, danmaku toggle, danmaku settings. Bottom
/// right: video fit, expand (fullscreen toggle). Fullscreen adds a
/// Persistent on-screen diagnostics pill (build 17): render path +
/// decoder + hwdec mode + buffer + download speed + drops, always
/// on the video, never hidden with the chrome, never truncated.
private struct DiagnosticTagPill: View {
    let engineName: String

    var body: some View {
        if engineName != "—" {
            Text(engineName)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .allowsHitTesting(false)
        }
    }
}

/// local danmaku composer in the middle of the bottom bar.
struct PlayerChromeView: View {
    @ObservedObject var service: LivePlayerService
    let title: String
    let subtitle: String
    let isFullscreen: Bool
    let isFavorite: Bool
    let danmakuEnabled: Bool
    let videoFill: Bool
    let qualityText: String
    let onBack: (() -> Void)?
    let onToggleFullscreen: () -> Void
    let onRefresh: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleDanmaku: () -> Void
    let onOpenDanmakuSettings: () -> Void
    let onOpenQuality: () -> Void
    let onToggleFit: () -> Void
    let onToggleLock: () -> Void
    var composer: AnyView?

    var body: some View {
        VStack(spacing: 0) {
            // Top bar.
            HStack(spacing: 8) {
                if let onBack {
                    Button { onBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer()
                if isFullscreen {
                    FullscreenClockView()
                    BatteryView()
                }
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            Spacer()
            // Bottom bar.
            HStack(spacing: 4) {
                chromeButton(systemName: service.isPlaying ? "pause.fill" : "play.fill") {
                    service.togglePlayPause()
                }
                chromeButton(systemName: "arrow.clockwise") { onRefresh() }
                chromeButton(systemName: isFavorite ? "heart.fill" : "heart") { onToggleFavorite() }
                chromeButton(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble") { onToggleDanmaku() }
                chromeButton(systemName: "ellipsis.bubble") { onOpenDanmakuSettings() }
                if let composer {
                    composer
                        .frame(maxWidth: 420)
                }
                Spacer()
                // (Build 17: the render-path tag moved out of the
                // chrome into the persistent DiagnosticTagPill on
                // the video — the chrome pill hid with the controls
                // and truncated the diagnostics to 140 pt.)
                if isFullscreen {
                    Button(qualityText) { onOpenQuality() }
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                chromeButton(systemName: videoFill ? "arrow.up.left.and.arrow.down.right" : "rectangle.expand.vertical") { onToggleFit() }
                chromeButton(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { onToggleFullscreen() }
            }
            .padding(.horizontal, HaoLiveDesign.pagePadding)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: service.state)
    }

    private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
    }
}

/// Clock (HH:mm) shown in the fullscreen top bar.
private struct FullscreenClockView: View {
    @State private var now = Date()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.string(from: now))
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

/// Battery level shown in the fullscreen top bar.
private struct BatteryView: View {
    @State private var level: Float = UIDevice.current.batteryLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: batteryIcon)
            Text("\(Int(level * 100))%")
                .font(.caption.bold())
        }
        .foregroundStyle(.white)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            level = UIDevice.current.batteryLevel
        }
    }

    private var batteryIcon: String {
        switch level {
        case ..<0.2: "battery.0"
        case ..<0.4: "battery.25"
        case ..<0.6: "battery.50"
        case ..<0.85: "battery.75"
        default: "battery.100"
        }
    }
}

// MARK: - Fullscreen player (Pure Live's fullscreen presentation)

/// Fullscreen landscape player. The same service container view as
/// the inline area (only one shows at a time), with the same overlay
/// controls on top plus a local danmaku composer. Entering locks
/// landscape and leaving restores portrait — rotating the phone
/// alone never changes orientation, and landscape works with the
/// system orientation lock ON because the AppDelegate overrides it.
struct FullscreenPlayerView: View {
    @ObservedObject var playerService: LivePlayerService
    let room: LiveRoom
    var danmakuItems: [DanmakuItem]
    var danmakuEnabled: Bool
    var danmakuFontSize: Double
    var danmakuOpacity: Double
    var danmakuSpeed: Double = 120
    var danmakuArea: Double = 1.0
    var danmakuFontWeight: Int = 500
    var danmakuLetterSpacing: Double = 0
    var danmakuStrokeEnabled: Bool = true
    var danmakuStrokeWidth: Double = 1.5
    var danmakuMaxVisibleCount: Int = 48
    var streams: [PlayStream]
    var isFavorite: Bool
    var onToggleFavorite: () -> Void
    var onToggleDanmaku: () -> Void
    var onOpenDanmakuSettings: () -> Void
    var onSelectQuality: (PlayStream) -> Void
    var onSendLocalDanmaku: (String) -> Void
    var onClose: () -> Void

    @State private var showingQualityPicker = false
    @State private var showControls = true
    @State private var locked = false
    @State private var volumeCard: (icon: String, percent: Int)?
    @State private var hideTask: Task<Void, Never>?
    @State private var volumeHideTask: Task<Void, Never>?
    @State private var videoFill = false
    @State private var dragStart: (x: CGFloat, brightness: CGFloat, volume: Float)?
    @State private var dragActive = false
    @State private var videoSize = CGSize.zero
    @State private var composerText = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContainerView(service: playerService)
                .ignoresSafeArea()
            if danmakuEnabled {
                DanmakuOverlayView(
                    items: danmakuItems,
                    fontSize: danmakuFontSize,
                    opacity: danmakuOpacity,
                    speed: danmakuSpeed,
                    area: danmakuArea,
                    fontWeight: danmakuFontWeight,
                    letterSpacing: danmakuLetterSpacing,
                    strokeEnabled: danmakuStrokeEnabled,
                    strokeWidth: danmakuStrokeWidth,
                    maxVisibleCount: danmakuMaxVisibleCount
                )
            }
            if playerService.state == .loading {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    if let notice = playerService.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            if case .failed(let message) = playerService.state {
                RoomPlaceholder(icon: "exclamationmark.triangle", message: message) {
                    playerService.refresh()
                }
            }
            if let card = volumeCard {
                HStack(spacing: 8) {
                    Image(systemName: card.icon)
                    ProgressView(value: Double(card.percent) / 100.0)
                        .tint(.white)
                        .frame(width: 100)
                    Text("\(card.percent)%")
                        .font(.caption.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: HaoLiveDesign.hudCornerRadius))
            }
            if showControls && !locked {
                PlayerChromeView(
                    service: playerService,
                    title: room.title,
                    subtitle: "\(room.anchorName) · \(room.platform.displayName)",
                    isFullscreen: true,
                    isFavorite: isFavorite,
                    danmakuEnabled: danmakuEnabled,
                    videoFill: videoFill,
                    qualityText: currentQualityText,
                    onBack: { onClose() },
                    onToggleFullscreen: { onClose() },
                    onRefresh: { playerService.refresh() },
                    onToggleFavorite: onToggleFavorite,
                    onToggleDanmaku: onToggleDanmaku,
                    onOpenDanmakuSettings: onOpenDanmakuSettings,
                    onOpenQuality: { showingQualityPicker = true },
                    onToggleFit: {
                        videoFill.toggle()
                        playerService.setVideoFit(fill: videoFill)
                    },
                    onToggleLock: { locked = true },
                    composer: AnyView(
                        HStack(spacing: 6) {
                            TextField("发送弹幕…", text: $composerText)
                                .textFieldStyle(.roundedBorder)
                                .font(.subheadline)
                            Button("发送") {
                                let text = composerText.trimmingCharacters(in: .whitespaces)
                                guard !text.isEmpty else { return }
                                onSendLocalDanmaku(text)
                                composerText = ""
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(HaoLiveDesign.liveRed, in: Capsule())
                            .disabled(composerText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    )
                )
            }
            if showControls && !locked {
                HStack {
                    Spacer()
                    Button { locked = true } label: {
                        Image(systemName: "lock.open")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .padding(.trailing, 8)
            }
            if locked {
                Button { locked = false } label: {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.black.opacity(0.6), in: Circle())
                }
            }
            // Persistent diagnostics pill (build 17) — same as the
            // inline player: always on the video, full text.
            VStack {
                DiagnosticTagPill(engineName: playerService.engineName)
                    .padding(.top, 64)
                    .padding(.leading, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { videoSize = $0 }
        .onTapGesture(count: 1) { handleVideoTap() }
        .onTapGesture(count: 2) {
            guard !locked else { return }
            onClose()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in handleVideoDragChanged(value) }
                .onEnded { _ in handleVideoDragEnded() }
        )
        .sheet(isPresented: $showingQualityPicker) {
            QualityPickerView(streams: streams, selectedStream: playerService.currentStream, onSelect: onSelectQuality)
        }
        .onAppear { OrientationLock.shared.lockLandscape() }
        .onDisappear {
            hideTask?.cancel()
            volumeHideTask?.cancel()
            OrientationLock.shared.lockPortrait()
        }
        .statusBarHidden()
        .onAppear { scheduleHideControls() }
    }

    private var currentQualityText: String {
        if let stream = playerService.currentStream {
            return "\(stream.quality) · \(stream.line)"
        }
        return "画质"
    }

    private func handleVideoTap() {
        if dragActive { return }
        if locked { return }
        if showControls && playerService.isPlaying {
            hideControls()
            return
        }
        showControlsTemporarily()
        if playerService.state == .paused {
            playerService.resume()
        }
    }

    private func handleVideoDragChanged(_ value: DragGesture.Value) {
        guard !locked else { return }
        if dragStart == nil {
            dragStart = (
                x: value.startLocation.x,
                brightness: UIScreen.main.brightness,
                volume: AVAudioSession.sharedInstance().outputVolume
            )
        }
        guard let start = dragStart else { return }
        if abs(value.translation.height) > 8 || abs(value.translation.width) > 8 {
            dragActive = true
        }
        guard dragActive else { return }
        let height = videoSize.height > 0 ? videoSize.height : 1
        let delta = -value.translation.height / height
        if start.x < videoSize.width / 2 {
            let brightness = min(max(start.brightness + delta, 0), 1)
            UIScreen.main.brightness = brightness
            showVolumeCard(icon: brightness <= 0 ? "sun.min.fill" : brightness < 0.5 ? "sun.min" : "sun.max.fill", percent: Int(brightness * 100))
        } else {
            let volume = min(max(start.volume + Float(delta), 0), 1)
            SystemVolume.shared.setVolume(volume)
            showVolumeCard(icon: volume <= 0 ? "speaker.slash.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill", percent: Int(volume * 100))
        }
    }

    private func handleVideoDragEnded() {
        dragStart = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { dragActive = false }
    }

    private func showControlsTemporarily() {
        showControls = true
        scheduleHideControls()
    }

    private func hideControls() {
        hideTask?.cancel()
        hideTask = nil
        showControls = false
    }

    private func scheduleHideControls() {
        hideTask?.cancel()
        guard playerService.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    private func showVolumeCard(icon: String, percent: Int) {
        volumeCard = (icon: icon, percent: percent)
        volumeHideTask?.cancel()
        volumeHideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            volumeCard = nil
        }
    }
}
