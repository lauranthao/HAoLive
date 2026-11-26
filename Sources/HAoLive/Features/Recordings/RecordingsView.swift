// RecordingsView.swift
// HAo Live — recordings center: the recording in progress (if any)
// with live time + size and a stop button, finished recordings with
// play + delete, total storage used, and watch history below.

import Combine
import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject private var recorder: LiveRecorder
    @EnvironmentObject private var historyStore: HistoryStore

    @State private var tick = Date()
    @State private var recordingToDelete: Recording?
    @State private var stopping = false

    private var store: RecordingStore { recorder.store }

    var body: some View {
        List {
            if let active = recorder.active {
                activeSection(active)
            }

            if !store.recordings.isEmpty {
                Section("已录制") {
                    ForEach(store.sorted) { recording in
                        NavigationLink(value: recording) {
                            recordingRow(recording)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                recordingToDelete = recording
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if store.totalSizeBytes > 0 {
                Section {
                    HStack {
                        Text("本地录制共占用")
                        Spacer()
                        Text(RecordingFormatters.size(store.totalSizeBytes))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            if !historyStore.entries.isEmpty {
                Section("观看历史") {
                    ForEach(historyStore.entries) { entry in
                        NavigationLink(value: entry.room) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.room.title).lineLimit(1)
                                    Text("\(entry.room.anchorName) · \(entry.room.platform.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(entry.watchedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if recorder.active == nil && store.recordings.isEmpty && historyStore.entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有录制",
                        systemImage: "record.circle",
                        description: Text("进直播间点「录制」，录好的内容会出现在这里，可离线回放")
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("录制")
        .navigationDestination(for: Recording.self) { recording in
            RecordingPlayerView(recording: recording, indexURL: store.indexURL(for: recording))
        }
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .toolbar {
            if !historyStore.entries.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空历史") { historyStore.clear() }
                }
            }
        }
        .alert("删除录制", isPresented: Binding(
            get: { recordingToDelete != nil },
            set: { if !$0 { recordingToDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let recording = recordingToDelete {
                    store.remove(recording)
                }
                recordingToDelete = nil
            }
            Button("取消", role: .cancel) { recordingToDelete = nil }
        } message: {
            Text("将删除「\(recordingToDelete?.title ?? "")」的录制文件，此操作无法恢复。")
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    // MARK: - In-progress recording

    private func activeSection(_ active: LiveRecorder.ActiveSession) -> some View {
        Section("正在录制") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(HaoLiveDesign.liveRed)
                        .frame(width: 8, height: 8)
                    Text(active.room.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text("\(active.room.anchorName) · \(active.room.platform.displayName) · \(active.stream.quality) · \(active.stream.line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Label(RecordingFormatters.duration(tick.timeIntervalSince(active.startedAt)), systemImage: "clock")
                    Label(RecordingFormatters.size(active.bytesSaved), systemImage: "internaldrive")
                    if active.hasGap {
                        Label("有缺失", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        stopping = true
                        Task {
                            await recorder.stop()
                            stopping = false
                        }
                    } label: {
                        Label("停止", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(stopping)
                }
                .font(.caption)
                Text("离开房间也不会停录；在后台时录制会暂停，回到前台后继续（中间漏掉的片段无法补回）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Finished recording row

    private func recordingRow(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(recording.title).lineLimit(1)
                if recording.status == .failed {
                    Text("已中断")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(HaoLiveDesign.liveRed.opacity(0.15), in: Capsule())
                        .foregroundStyle(HaoLiveDesign.liveRed)
                } else if recording.status == .incomplete {
                    Text("未完成")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text("\(recording.anchorName) · \(recording.platform.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(recording.startedAt, style: .date) · \(recording.displayDuration) · \(recording.displaySize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
