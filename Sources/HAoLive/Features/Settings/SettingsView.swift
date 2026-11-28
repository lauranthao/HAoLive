// SettingsView.swift
// HAo Live — settings: theme, player, danmaku, toolbox, cache,
// history retention, about. Local only; no account anywhere.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var historyStore: HistoryStore

    @State private var newKeyword = ""
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

    /// docs/version.json: the published (version, build). The tag
    /// alone cannot tell build 7 from build 8 — same lesson as
    /// HAo Music's updater. RULE: every build bump must update
    /// docs/version.json in the same commit.
    private struct VersionJSON: Decodable {
        var version: String
        var build: Int
        var ipa: String?
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var aboutInfo: HAoLiveAboutInfo {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return HAoLiveAboutInfo(version: version, build: build)
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
                    ForEach(["原画", "蓝光8M", "蓝光4M", "超清", "高清", "流畅"], id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                Picker("蜂窝网络优先画质", selection: $settingsStore.preferredQualityCellular) {
                    Text("自动").tag("")
                    ForEach(["原画", "蓝光8M", "蓝光4M", "超清", "高清", "流畅"], id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                Picker("优先线路", selection: $settingsStore.preferredLine) {
                    Text("自动").tag("")
                    ForEach(["线路1", "线路2", "线路3"], id: \.self) { line in
                        Text(line).tag(line)
                    }
                }
                Picker("硬件解码", selection: $settingsStore.hwdecMode) {
                    Text("自动").tag("auto")
                    Text("自动（安全）").tag("auto-safe")
                    Text("关闭").tag("no")
                }
                Toggle("显示数据", isOn: $settingsStore.showDiagnostics)
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
                    ToastCenter.shared.show("已清理图片缓存")
                }
                Text("只清理图片缓存；收藏和历史不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AboutSections(info: aboutInfo) {
                updateRow
            }
        }
        .navigationTitle("设置")
        .navigationDestination(item: $toolboxRoom) { room in
            LiveRoomView(room: room)
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
        let info = Bundle.main.infoDictionary
        let currentVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        let currentBuild = Int(info?["CFBundleVersion"] as? String ?? "") ?? 0
        // Primary: docs/version.json compares (version, build).
        // Unreachable (Pages off) -> fall back to the tag.
        if let url = URL(string: "https://lauranthao.github.io/HAoLive/version.json"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let latest = try? JSONDecoder().decode(VersionJSON.self, from: data) {
            let newerVersion = latest.version.compare(currentVersion, options: .numeric) == .orderedDescending
            let newerBuild = latest.version == currentVersion && latest.build > currentBuild
            updateStatus = (newerVersion || newerBuild) ? .available("v\(latest.version)") : .latest
            return
        }
        do {
            let url = URL(string: "https://api.github.com/repos/lauranthao/HAoLive/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(ReleaseJSON.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            updateStatus = latest == currentVersion ? .latest : .available(release.tagName)
        } catch {
            updateStatus = .failed
        }
    }

    // MARK: - Toolbox

    /// A minimal room from a pasted link or share text; LiveRoomView
    /// fetches the real detail (title / host / live status) on entry.
    /// The parse follows short links (v.douyin.com …), so it is async.
    private func roomFromLink(_ link: String) async -> LiveRoom? {
        guard let parsed = await LiveURLParser.parseLink(link) else { return nil }
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
        Task {
            toolboxMessage = "正在解析链接…"
            guard let room = await roomFromLink(toolboxLink) else {
                toolboxMessage = "链接无法识别：请粘贴哔哩哔哩、斗鱼、虎牙、抖音或快手的直播间链接"
                return
            }
            toolboxMessage = nil
            toolboxRoom = room
        }
    }

    private func copyToolboxStreamLink() async {
        guard let room = await roomFromLink(toolboxLink),
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
