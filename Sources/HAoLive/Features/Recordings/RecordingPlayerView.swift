// RecordingPlayerView.swift
// HAo Live — plays a finished recording back from disk.
// The local index.m3u8 points at the saved segments next to it, so
// AVPlayer plays it offline exactly like a remote HLS stream.

import AVKit
import SwiftUI

struct RecordingPlayerView: View {
    let recording: Recording
    let indexURL: URL

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(.black)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(.black)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(recording.title)
                    .font(.headline)
                Text("\(recording.anchorName) · \(recording.platform.displayName) · \(recording.quality)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("录制于 \(recording.startedAt, style: .date) \(recording.startedAt, style: .time) · \(recording.displayDuration) · \(recording.displaySize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if recording.hasGap {
                    Label("录制中有部分片段缺失，播放可能跳过一小段", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if recording.status == .incomplete {
                    Label("上次录制未正常结束，结尾可能缺失", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = recording.errorMessage, recording.status == .failed {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(HaoLiveDesign.liveRed)
                }
            }
            .padding(HaoLiveDesign.pagePadding)
            Spacer()
        }
        .navigationTitle("录制回放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let player = AVPlayer(url: indexURL)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
