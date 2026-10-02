import AppKit
import Carbon.HIToolbox
import Core
import SwiftUI

/// 设置页。分组：通用 / 快捷键 / 历史 / 贴回 / 隐私 / 外观 / 高级（字段见 docs/DESIGN.md）。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutsPane().tabItem { Label("快捷键", systemImage: "keyboard") }
            HistoryPane().tabItem { Label("历史", systemImage: "clock") }
            PastePane().tabItem { Label("贴回", systemImage: "doc.on.clipboard") }
            PrivacyPane().tabItem { Label("隐私", systemImage: "lock") }
            AppearancePane().tabItem { Label("外观", systemImage: "paintbrush") }
            AdvancedPane().tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 400)
        .padding(4)
    }
}

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorderModel = HotkeyRecorder.shared.model

    var body: some View {
        Form {
            Section("唤醒热键") {
                HStack {
                    Button("⇧⌘V") { setHotkey(UInt32(cmdKey) | UInt32(shiftKey), UInt32(kVK_ANSI_V)) }
                    Button("⇧⌘C") { setHotkey(UInt32(cmdKey) | UInt32(shiftKey), UInt32(kVK_ANSI_C)) }
                    Button("⌥⌘V") { setHotkey(UInt32(cmdKey) | UInt32(optionKey), UInt32(kVK_ANSI_V)) }
                    if recorderModel.isRecording {
                        Button("停止录制") { HotkeyRecorder.shared.stop() }
                    } else {
                        Button("录制…") { HotkeyRecorder.shared.start() }
                    }
                    Spacer()
                    Text(recorderModel.isRecording ? "按下新快捷键…" : "当前：\(settings.hotkeySummary)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, design: .monospaced))
            }
            Section("启动") {
                Toggle("登录时启动", isOn: $settings.launchAtLogin)
            }
            Section("面板行为") {
                Toggle("失焦自动关闭", isOn: $settings.blurCloseEnabled)
                HStack {
                    Text("关闭延迟")
                    Slider(value: $settings.blurCloseDelay, in: 0...2, step: 0.05)
                    Text(String(format: "%.2fs", settings.blurCloseDelay))
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Stepper(value: $settings.autoUnfoldLines, in: 0...8) {
                    HStack {
                        Text("选中停下后展开")
                        Spacer()
                        Text(settings.autoUnfoldLines == 0 ? "不展开" : "最多 \(settings.autoUnfoldLines) 行")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setHotkey(_ mods: UInt32, _ code: UInt32) {
        settings.hotkeyModifiersRaw = mods
        settings.hotkeyKeyCode = code
    }
}

/// 面板里的快捷键：一张表列全部动作。点右边的快捷键，再按新的组合。
private struct ShortcutsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        Form {
            Section {
                ForEach(PanelAction.allCases.filter(\.isCustomizable), id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutButton(action: action, combo: settings.keymap.combo(for: action), recorder: recorder)
                    }
                }
            } header: {
                Text("面板里的快捷键")
            } footer: {
                Text(recorder.note ?? "点右边的快捷键，再按新的组合；Esc 取消，⌫ 清除。")
                    .foregroundStyle(recorder.note == nil ? .secondary : .primary)
            }
            Section("固定") {
                fixedRow("贴回", "↩")
                fixedRow("关闭面板", "Esc")
                fixedRow("上一条 / 下一条", "↑  ↓")
                fixedRow("贴视口里的第 n 条", "⌘1 – ⌘9")
                fixedRow("切换分类（搜索框为空时）", "←  →")
            }
            Section {
                HStack {
                    Spacer()
                    Button("恢复默认") {
                        recorder.stop()
                        settings.keymapOverrides = [:]
                        recorder.note = nil
                    }
                    .disabled(settings.keymapOverrides.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear { recorder.stop() }
    }

    private func fixedRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).foregroundStyle(.secondary)
        }
    }
}

/// 一格快捷键：平时显示组合（没有就是"—"），点一下开始录，录制中高亮。
private struct ShortcutButton: View {
    let action: PanelAction
    let combo: KeyCombo?
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        let recording = recorder.recording == action
        let label = Text(recording ? "按下新快捷键…" : (combo?.display ?? "—"))
            .frame(minWidth: 96)
        if recording {
            Button { recorder.stop() } label: { label }
                .buttonStyle(.borderedProminent)
        } else {
            Button { recorder.start(action) } label: { label }
                .buttonStyle(.bordered)
        }
    }
}

private struct HistoryPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("保留时长") {
                Picker("保留时长", selection: $settings.retentionPreset) {
                    Text("24 小时").tag("24h")
                    Text("7 天").tag("7d")
                    Text("30 天").tag("30d")
                    Text("永久").tag("forever")
                }
                .pickerStyle(.segmented)
            }
            Section("容量") {
                Stepper("最多保留 \(settings.hardLimit) 条", value: $settings.hardLimit, in: 100...5000, step: 100)
                Stepper("单条截断 \(settings.maxSaveLength) 字", value: $settings.maxSaveLength, in: 1000...50000, step: 1000)
            }
            Section {
                Toggle("收藏永久保留（不被清理）", isOn: $settings.favoritesPermanent)
                Text("从本 App 一键贴回过的记录始终保留，不占普通历史条数；仅复制不算。仍可手动删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct PastePane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("贴回格式") {
                Toggle("贴回为纯文本（去除格式）", isOn: .constant(true))
                    .disabled(true)
                Text("当前版本仅存储纯文本，贴回始终是纯文本；富文本保留不在 v1 范围。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("图片贴回") {
                Picker("图片贴回方式", selection: $settings.imagePasteAsFile) {
                    Text("图片").tag(false)
                    Text("文件").tag(true)
                }
                .pickerStyle(.segmented)
                Text("“文件”会以原始图片文件 URL 贴入，适用于需要文件引用的 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct PrivacyPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("会话") {
                Toggle("隐私模式（本次运行不记录任何复制）", isOn: $settings.privacyMode)
            }
            Section("密钥记录") {
                Toggle("自动排除疑似密钥（不进入历史）", isOn: $settings.autoExcludeSecrets)
                Text("开启后，复制 API Key / Token 等疑似密钥不会写入历史，也就不能在面板里把它标记为密钥存进 jt。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("网页来源") {
                Toggle("记录浏览器页面来源", isOn: $settings.captureBrowserSource)
                Text("支持 Helium、Chrome。普通页面的地址仅保存在本机；无痕窗口不记。首次使用可能需要系统授权，展开记录后才显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AppearancePane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("视觉风格") {
                Picker("视觉风格", selection: $settings.appearanceStyle) {
                    Text("自动").tag("auto")
                    Text("Liquid Glass").tag("glass")
                    Text("兼容").tag("compatible")
                }
                .pickerStyle(.segmented)
                Text("兼容：用系统 vibrancy 材质代替 Liquid Glass，下次启动生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("面板宽度") {
                Slider(value: $settings.panelWidth, in: 520...760, step: 20)
                Text("\(Int(settings.panelWidth)) px（下次启动生效）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AdvancedPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("编辑器") {
                TextField("默认编辑器", text: $settings.editorApp, prompt: Text("留空 = 系统默认"))
                Text("⌘O 用它打开文本，填应用名，例如 Zed / Neovide / TextEdit；留空用系统默认的 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OCR 语言") {
                ForEach(AppSettings.defaultOCRLanguages, id: \.self) { language in
                    Toggle(languageLabel(language), isOn: ocrBinding(language))
                }
            }

            Section("数据") {
                Button("在访达中显示数据目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([dataDir()])
                }
            }

            Section("危险区") {
                Button("清空历史…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "清空全部剪贴板历史？"
                    alert.informativeText = "此操作会删除所有历史记录和图片文件。"
                    alert.addButton(withTitle: "清空")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NotificationCenter.default.post(name: .jtbClearHistoryRequest, object: nil)
                    }
                }
            }

            Section("关于") {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0-dev"
                Text("jiantieban v\(version)")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func languageLabel(_ language: String) -> String {
        switch language {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁体中文"
        case "en-US": return "英文"
        default: return language
        }
    }

    private func ocrBinding(_ language: String) -> Binding<Bool> {
        Binding(
            get: { settings.ocrLanguages.contains(language) },
            set: { enabled in
                if enabled {
                    if !settings.ocrLanguages.contains(language) {
                        settings.ocrLanguages.append(language)
                    }
                } else {
                    settings.ocrLanguages.removeAll { $0 == language }
                }
            }
        )
    }
}
