// SearchView.swift
// HAo Live — cross-platform search (HAo's own layer):
// one keyword searches all five platforms in parallel,
// results merged in platform order, deduped by anchor + title.

import SwiftUI

struct SearchView: View {
    @State private var keyword = ""
    @State private var results: [LiveRoom] = []
    @State private var isSearching = false
    @State private var didSearch = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if isSearching {
                ProgressView().padding(.top, 60)
            } else if didSearch && results.isEmpty {
                ContentUnavailableView.search(text: keyword)
                    .padding(.top, 40)
            } else if didSearch {
                List {
                    ForEach(results) { room in
                        NavigationLink(value: room) {
                            RoomCard(room: room)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            } else {
                ContentUnavailableView(
                    "跨平台搜索",
                    systemImage: "magnifyingglass",
                    description: Text("一次搜遍哔哩哔哩、斗鱼、虎牙、抖音、快手")
                )
                .padding(.top, 40)
            }
            Spacer()
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: LiveRoom.self) { room in
            LiveRoomView(room: room)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜房间、搜主播", text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }
                .onChange(of: keyword) { _, newValue in
                    // 300ms debounce: type, pause, then search.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard newValue == keyword, !newValue.isEmpty else { return }
                        await search()
                    }
                }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    results = []
                    didSearch = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(HaoLiveDesign.pagePadding)
    }

    private func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let perPlatform = await withTaskGroup(of: [LiveRoom].self) { group in
            for site in SiteRegistry.sites {
                group.addTask {
                    (try? await site.searchRooms(keyword: trimmed)) ?? []
                }
            }
            var collected: [[LiveRoom]] = []
            for await list in group {
                collected.append(list)
            }
            return collected
        }
        results = RoomSearchMerger.merge(perPlatform)
        didSearch = true
    }
}
