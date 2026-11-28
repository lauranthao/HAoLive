// AboutView.swift
// HAo Live — about page, mirroring HAo Music's AboutView: header
// (app icon + name + subtitle), version/build/developer rows, update
// row, project links, licenses page, disclaimer sheet. Live has no
// website, so there is no 官网 row. The update row itself lives in
// SettingsView (it owns the update state) and is passed in.

import SwiftUI

/// Product facts shown on the About page. Version and build come from
/// the bundle; the links are HAo Live's own repository.
struct HAoLiveAboutInfo {
    let version: String
    let build: String

    var name: String { "HAo Live" }
    var developer: String { "HAo / lauranthao" }
    var repository: String { "lauranthao/HAoLive" }

    var repositoryURL: URL? { URL(string: "https://github.com/lauranthao/HAoLive") }
    var issuesURL: URL? { repositoryURL?.appendingPathComponent("issues") }
    var releasesURL: URL? { repositoryURL?.appendingPathComponent("releases") }

    /// `host/path` without scheme or trailing slash, for compact display.
    static func displayAddress(_ url: URL) -> String {
        var text = (url.host ?? "") + url.path
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// About section: header, version rows, update row, changelog link,
/// project links, the licenses page and the disclaimer button.
struct AboutSections<UpdateRow: View>: View {
    let info: HAoLiveAboutInfo
    @ViewBuilder let updateRow: () -> UpdateRow
    @State private var showsDisclaimer = false

    var body: some View {
        Section {
            AboutHeader(info: info)

            Group {
                LabeledContent { Text(info.version) } label: { Label("版本", systemImage: "number") }
                LabeledContent { Text(info.build) } label: { Label("构建号", systemImage: "hammer") }
                LabeledContent { Text(info.developer) } label: { Label("开发者", systemImage: "person") }
            }
            .textSelection(.enabled)

            updateRow()

            NavigationLink("更新日志") { ChangelogView() }

            if let url = info.repositoryURL {
                AboutLinkRow(title: "GitHub 仓库", systemImage: "chevron.left.forwardslash.chevron.right",
                             detail: info.repository, url: url)
            }
            if let url = info.issuesURL {
                AboutLinkRow(title: "问题反馈", systemImage: "exclamationmark.bubble", detail: nil, url: url)
            }
            if let url = info.releasesURL {
                AboutLinkRow(title: "版本发布", systemImage: "shippingbox", detail: nil, url: url)
            }

            NavigationLink("开源许可与致谢") { LicensesView() }

            Button {
                showsDisclaimer = true
            } label: {
                Label("查看完整免责声明", systemImage: "exclamationmark.shield")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("关于")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("HAo Live 以 GNU AGPL v3.0 开源。")
                Text("HAo Live 参考 Pure Live 的功能设计，界面与实现均为 HAo 自己所写；不登录，不上传任何数据。直播内容版权归原权利人所有。")
            }
        }
        .sheet(isPresented: $showsDisclaimer) {
            DisclaimerSheet()
        }
    }
}

private struct AboutHeader: View {
    let info: HAoLiveAboutInfo

    var body: some View {
        VStack(spacing: 10) {
            HAoLiveAppIconImage()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(info.name)
                .font(.title2.bold())
            Text("多平台直播客户端")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct HAoLiveAppIconImage: View {
    var body: some View {
        if let icon = Self.primaryIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Image(systemName: "play.tv")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
        }
    }

    private static let primaryIcon: UIImage? = {
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let name = (primary["CFBundleIconFiles"] as? [String])?.last,
                  let image = UIImage(named: name) else { continue }
            return image
        }
        return nil
    }()
}

private struct AboutLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String?
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(url.absoluteString))
    }
}

private struct DisclaimerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("HAo Live 以 GNU AGPL v3.0 开源。")
                    Text("HAo Live 是非官方的第三方直播客户端，与各直播平台无关。参考 Pure Live 的功能设计，界面与实现均为 HAo 自己所写。")
                    Text("本应用不要求登录，不收集、不上传任何数据。直播内容与数据均来自各直播平台，版权归原权利人所有。")
                    Text("使用本应用即表示你同意遵守各平台的使用条款，并自行承担使用风险。")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("免责声明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// This app's own release notes (what changed in each build).
struct ChangelogView: View {
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
struct LicensesView: View {
    private struct Entry {
        var name: String
        var license: String
        var url: String
    }

    private let entries = [
        Entry(name: "Pure Live", license: "AGPL-3.0", url: "https://github.com/wzgrx/PureLive"),
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
