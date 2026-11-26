// SettingsView.swift
// HAo Live — settings: theme, player, danmaku, cache, about.
// Local only; no account anywhere in the app.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var newKeyword = ""
    @State private var showingClearCacheDone = false

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
                HStack {
                    Text("字号")
                    Slider(value: $settingsStore.danmakuFontSize, in: 12...20, step: 1)
                    Text("\(Int(settingsStore.danmakuFontSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("不透明度")
                    Slider(value: $settingsStore.danmakuOpacity, in: 0.3...1.0, step: 0.1)
                    Text(String(format: "%.0f%%", settingsStore.danmakuOpacity * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }

            Section("缓存") {
                LabeledContent("本地数据", value: settingsStore.cacheSizeText)
                Button("清理缓存", role: .destructive) {
                    settingsStore.clearCache()
                    showingClearCacheDone = true
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1.0 (1)")
                LabeledContent("参照", value: "Pure Live（仅功能）")
                Text("HAo Live 参考 Pure Live 的功能设计，界面与实现均为 HAo 自己所写；不登录，不上传任何数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .alert("已清理", isPresented: $showingClearCacheDone) {
            Button("好", role: .cancel) {}
        }
    }
}
