// LiveRoomView.swift
// HAo Live — live room page (HAo's own room layout).
// Portrait entry, 16:9 player on top, anchor + title below,
// action row, danmaku overlay. Entering a room records history.

import AVKit
import SwiftUI

struct LiveRoomView: View {
    let room: LiveRoom

    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @StateObject private var playerService = LivePlayerService()
    @State private var streams: [PlayStream] = []
    @State private var showingQualityPicker = false
    @State private var danmakuEngine = DanmakuEngine()
    @State private var visibleDanmaku: [DanmakuItem] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                playerArea
                infoArea
                actionRow
                Divider().padding(.top, 12)
                aboutArea
            }
        }
        .navigationTitle(room.anchorName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    favoritesStore.toggle(room)
                } label: {
                    Image(systemName: favoritesStore.isFavorite(room) ? "heart.fill" : "heart")
                        .foregroundStyle(favoritesStore.isFavorite(room) ? HaoLiveDesign.liveRed : .primary)
                }
            }
        }
        .sheet(isPresented: $showingQualityPicker) {
            QualityPickerView(streams: streams, selectedStream: playerService.currentStream) { stream in
                playerService.switchStream(stream)
            }
        }
        .task { await enterRoom() }
        .onDisappear {
            playerService.stop()
        }
    }

    // MARK: - Player

    private var playerArea: some View {
        ZStack {
            VideoPlayer(player: playerService.player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
            if settingsStore.danmakuEnabled {
                DanmakuOverlayView(
                    items: visibleDanmaku,
                    fontSize: settingsStore.danmakuFontSize,
                    opacity: settingsStore.danmakuOpacity
                )
            }
            if case .failed(let message) = playerService.state {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(message)
                        .font(.subheadline)
                }
                .foregroundStyle(.white)
                .padding()
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Info

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(HaoLiveDesign.liveRed, in: Capsule())
                    .foregroundStyle(.white)
                Text(room.platform.displayName)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(hex: room.platform.colorHex).opacity(0.15), in: Capsule())
                    .foregroundStyle(Color(hex: room.platform.colorHex))
                Spacer()
                Label(room.viewerCountText, systemImage: "eye.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(room.title)
                .font(.headline)
            Text(room.anchorName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let category = room.categoryName {
                Text("分区：\(category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.top, 12)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                playerService.togglePlayPause()
            } label: {
                Label(playerService.isPlaying ? "暂停" : "播放", systemImage: playerService.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)

            Button {
                showingQualityPicker = true
            } label: {
                Label(currentQualityText, systemImage: "gearshape.fill")
            }
            .buttonStyle(.bordered)
            .disabled(streams.isEmpty)

            Button {
                settingsStore.danmakuEnabled.toggle()
            } label: {
                Label("弹幕", systemImage: settingsStore.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal, HaoLiveDesign.pagePadding)
        .padding(.top, 12)
    }

    private var aboutArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("房间信息")
                .font(.headline)
            LabeledContent("房间号", value: room.roomID)
            LabeledContent("平台", value: room.platform.displayName)
            LabeledContent("状态", value: room.isLive ? "直播中" : "未开播")
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HaoLiveDesign.liveRed)
            }
        }
        .padding(HaoLiveDesign.pagePadding)
    }

    private var currentQualityText: String {
        if let stream = playerService.currentStream {
            return "\(stream.quality) · \(stream.line)"
        }
        return "画质"
    }

    // MARK: - Loading

    private func enterRoom() async {
        historyStore.record(room)
        danmakuEngine = DanmakuEngine(
            blockedKeywords: settingsStore.blockedKeywords,
            blockedUsers: []
        )
        guard let site = SiteRegistry.site(for: room.platform) else {
            loadError = "该平台暂未接入"
            return
        }
        do {
            streams = try await site.playURLs(roomID: room.roomID)
            playerService.open(
                streams: streams,
                preferredQuality: settingsStore.preferredQuality.isEmpty ? nil : settingsStore.preferredQuality,
                preferredLine: settingsStore.preferredLine.isEmpty ? nil : settingsStore.preferredLine
            )
        } catch {
            loadError = error.localizedDescription
            playerService.open(streams: [], preferredQuality: nil, preferredLine: nil)
        }
        startDanmakuLoop(site: site)
    }

    /// Feeds sample danmaku lines into the overlay every 1.5s.
    /// Runs until the view's task is cancelled (room closed).
    private func startDanmakuLoop(site: any LiveSite) {
        Task { @MainActor in
            let samples = await site.sampleDanmaku(roomID: room.roomID)
            guard !samples.isEmpty else { return }
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard settingsStore.danmakuEnabled else { continue }
                let item = samples[index % samples.count]
                index += 1
                if danmakuEngine.accept(item) {
                    withAnimation(.easeIn(duration: 0.3)) {
                        visibleDanmaku.append(item)
                        if visibleDanmaku.count > 8 {
                            visibleDanmaku.removeFirst(visibleDanmaku.count - 8)
                        }
                    }
                }
            }
        }
    }
}
