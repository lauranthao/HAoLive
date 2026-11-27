// HistoryView.swift
// HAo Live — watch history: rooms watched, tap to reopen, clear all.
// (Was the 录制 tab's lower half; recording was removed, history stays.)

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var historyStore: HistoryStore

    var body: some View {
        List {
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
            } else {
                Section {
                    ContentUnavailableView(
                        "还没有观看历史",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("看过的直播间会出现在这里")
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("历史")
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
