// SettingsView.swift
// HAo Live — settings: theme, player, danmaku, toolbox, cache,
// history retention, about. Local only; no account anywhere.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var historyStore: HistoryStore

    @State private var newKeyword = ""
    @State private var showingClearCacheDone = false
    @State private var toolboxLink = ""
    @State private var toolboxRoom: LiveRoom?
    @State private var toolboxMessage: String?
    @State private var isFetchingStreamLink = false
    @State private var updateStatus: UpdateStatus = .unknown

    private enum UpdateStatus {
        case unknown
        case checking
        case latest
        case available(String)
        case failed
    }

    private struct ReleaseJSON: Decodable {
        var tagName: String
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private let historyLimits = [20, 50, 100, 200, 500]

    var body: some View {
        List {
            Section("外观") {
                Picker("主题", selection: $settingsStore.theme) {
                    ForEach(HaoLiveTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }

            Section("播放器") {
                Picker("优先画质", selection: $settingsStore.preferredQuality) {
                    Text("自动").tag("")
                    ForEach(["原画", "超清", "高清", "流畅"], id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                Picker("优先线路", selection: $settingsStore.preferredLine) {
                    Text("自动").tag("")
                    ForEach(["线路1", "线路2"], id: \.self) { line in
                        Text(line).tag(line)
                    }
                }
            }

            Section("弹幕") {
                Toggle("显示弹幕", isOn: $settingsStore.danmakuEnabled)
                NavigationLink("弹幕详细设置") {
                    DanmakuSettingsForm(settingsStore: settingsStore)
                        .navigationTitle("弹幕设置")
                        .navigationBarTitleDisplayMode(.inline)
                }
                HStack {
                    TextField("屏蔽关键词", text: $newKeyword)
                    Button("添加") {
                        let word = newKeyword.trimmingCharacters(in: .whitespaces)
                        guard !word.isEmpty else { return }
                        settingsStore.blockedKeywords.append(word)
                        newKeyword = ""
                    }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settingsStore.blockedKeywords, id: \.self) { word in
                    Text(word)
                }
                .onDelete { offsets in
                    settingsStore.blockedKeywords.remove(atOffsets: offsets)
                }
                if !settingsStore.blockedUsers.isEmpty {
                    ForEach(settingsStore.blockedUsers, id: \.self) { user in
                        HStack {
                            Text(user)
                            Spacer()
                            Text("已屏蔽用户")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        settingsStore.blockedUsers.remove(atOffsets: offsets)
                    }
                }
            }

            Section("工具箱") {
                TextField("粘贴直播间链接", text: $toolboxLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("打开直播间") { openToolboxRoom() }
                        .disabled(toolboxLink.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("复制直链") {
                        Task { await copyToolboxStreamLink() }
                    }
                    .disabled(toolboxLink.trimmingCharacters(in: .whitespaces).isEmpty || isFetchingStreamLink)
                    if isFetchingStreamLink {
                        ProgressView()
                    }
                }
                Button("从剪贴板粘贴") {
                    toolboxLink = UIPasteboard.general.string ?? ""
                }
                if let message = toolboxMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("支持哔哩哔哩、斗鱼、虎牙、抖音、快手的直播间链接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("历史") {
                Picker("保留条数", selection: $historyStore.limit) {
                    ForEach(historyLimits, id: \.self) { limit in
                        Text("\(limit) 条").tag(limit)
                    }
                    Text("不限").tag(0)
                }
                Text("超出条数的旧记录自动删除；0 表示不限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("缓存") {
                LabeledContent("图片缓存", value: settingsStore.imageCacheSizeText)
                Button("清理图片缓存", role: .destructive) {
                    CoverImageCache.shared.clear()
                    showingClearCacheDone = true
                }
                Text("只清理图片缓存；收藏和历史不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("版本", value: appVersionText)
                updateRow
                NavigationLink("更新日志") { ChangelogView() }
                NavigationLink("开源许可与致谢") { LicensesView() }
                Text("HAo Live 参考 Pure Live 的功能设计，界面与实现均为 HAo 自己所写；不登录，不上传任何数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationDestination(item: $toolboxRoom) { room in
            LiveRoomView(room: room)
        }
        .alert("已清理图片缓存", isPresented: $showingClearCacheDone) {
            Button("好", role: .cancel) {}
        }
    }

    // MARK: - Update check

    private var updateRow: some View {
        HStack {
            Text("检查更新")
            Spacer()
            switch updateStatus {
            case .unknown:
                Button("检查") { Task { await checkForUpdate() } }
            case .checking:
                ProgressView()
            case .latest:
                Text("已是最新版本")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .available(let tag):
                Button("有新版本 \(tag)") {
                    if let url = URL(string: "https://github.com/lauranthao/HAoLive/releases") {
                        UIApplication.shared.open(url)
                    }
                }
            case .failed:
                Button("检查失败，点此重试") { Task { await checkForUpdate() } }
            }
        }
    }

    private func checkForUpdate() async {
        updateStatus = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/lauranthao/HAoLive/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let release = try JSONDecoder().decode(ReleaseJSON.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            updateStatus = latest == current ? .latest : .available(release.tagName)
        } catch {
            updateStatus = .failed
        }
    }

    // MARK: - Toolbox

    /// A minimal room from a pasted link; LiveRoomView fetches the
    /// real detail (title / host / live status) on entry.
    private func roomFromLink(_ link: String) -> LiveRoom? {
        guard let parsed = LiveURLParser.parse(link) else { return nil }
        return LiveRoom(
            id: "\(parsed.platform.rawValue)-\(parsed.roomID)",
            platform: parsed.platform,
            roomID: parsed.roomID,
            title: "直播间 \(parsed.roomID)",
            anchorName: parsed.roomID,
            anchorAvatarURL: nil,
            coverURL: nil,
            categoryName: nil,
            viewerCount: 0,
            isLive: true
        )
    }

    private func openToolboxRoom() {
        guard let room = roomFromLink(toolboxLink) else {
            toolboxMessage = "链接无法识别：请粘贴哔哩哔哩、斗鱼、虎牙、抖音或快手的直播间链接"
            return
        }
        toolboxMessage = nil
        toolboxRoom = room
    }

    private func copyToolboxStreamLink() async {
        guard let room = roomFromLink(toolboxLink),
              let site = SiteRegistry.site(for: room.platform) else {
            toolboxMessage = "链接无法识别：请粘贴哔哩哔哩、斗鱼、虎牙、抖音或快手的直播间链接"
            return
        }
        isFetchingStreamLink = true
        defer { isFetchingStreamLink = false }
        do {
            let streams = try await site.playURLs(room: room)
            guard let first = streams.first else {
                toolboxMessage = "该直播间暂无可播放的地址"
                return
            }
            UIPasteboard.general.string = first.url.absoluteString
            toolboxMessage = "已复制直链（\(first.quality) · \(first.line)）"
        } catch {
            toolboxMessage = "获取直链失败：\(error.localizedDescription)"
        }
    }
}

/// This app's own release notes (what changed in each build).
private struct ChangelogView: View {
    var body: some View {
        List {
            Section("0.1.0 build 7") {
                Text("收藏实时更新、标签与排序；热门/分类/搜索分页；弹幕滚动 lanes 与完整设置；工具箱；历史按条数保留。")
            }
            Section("0.1.0 build 6") {
                Text("mpv 播放器（系统播放器兜底）；虎牙/斗鱼/快手/抖音线路按 Pure Live 重写。")
            }
            Section("0.1.0 build 5") {
                Text("各站签名线路、封面加载、全屏横屏；虎牙/快手弹幕。")
            }
            Section("0.1.0 build 4") {
                Text("首版：五站推荐、分类、搜索、收藏、历史。")
            }
        }
        .navigationTitle("更新日志")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Third-party code this app builds on, and its licenses.
private struct LicensesView: View {
    private struct Entry {
        var name: String
        var license: String
        var url: String
    }

    private let entries = [
        Entry(name: "Pure Live", license: "AGPL-3.0", url: "https://github.com/liuchuancong/pure_live"),
        Entry(name: "MPVKit (libmpv)", license: "LGPL-3.0", url: "https://github.com/mpvkit/MPVKit"),
    ]

    var body: some View {
        List(entries, id: \.name) { entry in
            Button {
                if let url = URL(string: entry.url) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.license)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("开源许可与致谢")
        .navigationBarTitleDisplayMode(.inline)
    }
}
