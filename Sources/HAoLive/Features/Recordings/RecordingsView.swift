// RecordingsView.swift
// HAo Live — recordings center shell.
// Recording live streams to local files is a later leg;
// this page reserves the space and explains the plan.

import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject private var historyStore: HistoryStore

    var body: some View {
        List {
            Section {
                ContentUnavailableView(
                    "还没有录制",
                    systemImage: "record.circle",
                    description: Text("录制直播流到本地的功能即将推出，录好的内容会出现在这里")
                )
                .listRowBackground(Color.clear)
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
        }
        .navigationTitle("录制")
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
    }
}
