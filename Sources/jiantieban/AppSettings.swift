import Carbon.HIToolbox
import Combine
import Core
import Foundation
import ServiceManagement

extension Notification.Name {
    /// 热键配置变化 → AppDelegate 重新注册
    static let jtbHotkeyChanged = Notification.Name("jtb.hotkeyChanged")
    /// 隐私策略变化 → AppDelegate 更新 IngestPipeline.policy
    static let jtbPolicyChanged = Notification.Name("jtb.policyChanged")
    /// 历史策略变化 → AppDelegate 更新 ClipStore.config
    static let jtbHistoryChanged = Notification.Name("jtb.historyChanged")
    /// 设置页请求清空历史
    static let jtbClearHistoryRequest = Notification.Name("jtb.clearHistoryRequest")
    /// OCR 语言变化 → AppDelegate 更新 IngestPipeline
    static let jtbOCRLanguagesChanged = Notification.Name("jtb.ocrLanguagesChanged")
}

/// 全局设置（UserDefaults-backed），设置页与运行时行为都读这里。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: 热键（默认 ⇧⌘V，可在设置页切换）
    @Published var hotkeyModifiersRaw: UInt32 {
        didSet { defaults.set(hotkeyModifiersRaw, forKey: "hotkeyModifiers"); notify(.jtbHotkeyChanged) }
    }
    @Published var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode"); notify(.jtbHotkeyChanged) }
    }

    // MARK: 历史
    @Published var retentionPreset: String {
        didSet { defaults.set(retentionPreset, forKey: "retentionPreset"); notify(.jtbHistoryChanged) }
    }
    @Published var hardLimit: Int {
        didSet { defaults.set(hardLimit, forKey: "hardLimit"); notify(.jtbHistoryChanged) }
    }
    @Published var maxSaveLength: Int {
        didSet { defaults.set(maxSaveLength, forKey: "maxSaveLength"); notify(.jtbHistoryChanged) }
    }
    @Published var favoritesPermanent: Bool {
        didSet { defaults.set(favoritesPermanent, forKey: "favoritesPermanent"); notify(.jtbHistoryChanged) }
    }

    // MARK: 贴回
    @Published var plainTextPaste: Bool {
        didSet { defaults.set(plainTextPaste, forKey: "plainTextPaste") }
    }
    @Published var imagePasteAsFile: Bool {
        didSet { defaults.set(imagePasteAsFile, forKey: "imagePasteAsFile") }
    }

    // MARK: 隐私
    @Published var privacyMode: Bool {
        didSet { defaults.set(privacyMode, forKey: "privacyMode"); notify(.jtbPolicyChanged) }
    }
    @Published var autoExcludeSecrets: Bool {
        didSet { defaults.set(autoExcludeSecrets, forKey: "autoExcludeSecrets"); notify(.jtbPolicyChanged) }
    }
    @Published var captureBrowserSource: Bool {
        didSet { defaults.set(captureBrowserSource, forKey: "captureBrowserSource") }
    }

    // MARK: 外观
    @Published var appearanceStyle: String {
        didSet { defaults.set(appearanceStyle, forKey: "appearanceStyle") }
    }
    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: "panelWidth") }
    }
    /// 选中停下后文本行原地展开的最多行数；0 = 不自动展开（⌘R 仍可展开全部）。设置 → 通用 → 面板行为
    @Published var autoUnfoldLines: Int {
        didSet { defaults.set(autoUnfoldLines, forKey: "autoUnfoldLines") }
    }

    // MARK: 面板快捷键
    /// 设置页改过的快捷键：动作 → 组合写法（"" = 不设）。只存改过的，见 Keymap.storedOverrides
    @Published var keymapOverrides: [String: String] {
        didSet { defaults.set(keymapOverrides, forKey: "keymapOverrides") }
    }

    /// 面板用的键位表（默认表 + 设置页改过的）。面板每次打开时读
    var keymap: Keymap {
        get { Keymap.withStoredOverrides(keymapOverrides) }
        set { keymapOverrides = newValue.storedOverrides }
    }

    // MARK: 高级
    /// ⌘O 打开文本用的 App 名；空 = 系统默认 App
    @Published var editorApp: String {
        didSet { defaults.set(editorApp, forKey: "editorApp") }
    }
    @Published var ocrLanguages: [String] {
        didSet {
            defaults.set(ocrLanguages, forKey: "ocrLanguages")
            notify(.jtbOCRLanguagesChanged)
        }
    }

    // MARK: 行为
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: "firstRunDone") }
    }
    @Published var blurCloseEnabled: Bool {
        didSet { defaults.set(blurCloseEnabled, forKey: "blurCloseEnabled") }
    }
    @Published var blurCloseDelay: Double {
        didSet { defaults.set(blurCloseDelay, forKey: "blurCloseDelay") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }

    private init() {
        let d = UserDefaults.standard
        self.hotkeyModifiersRaw = d.uint32("hotkeyModifiers", fallback: UInt32(cmdKey) | UInt32(shiftKey))
        self.hotkeyKeyCode = d.uint32("hotkeyKeyCode", fallback: UInt32(kVK_ANSI_V))
        self.retentionPreset = d.string(forKey: "retentionPreset") ?? "24h"
        self.hardLimit = d.int("hardLimit", fallback: 600)
        self.maxSaveLength = d.int("maxSaveLength", fallback: 12000)
        self.favoritesPermanent = d.bool("favoritesPermanent", fallback: true)
        self.plainTextPaste = d.bool("plainTextPaste", fallback: true)
        self.imagePasteAsFile = d.bool("imagePasteAsFile", fallback: false)
        self.privacyMode = d.bool("privacyMode", fallback: false)
        self.autoExcludeSecrets = d.bool("autoExcludeSecrets", fallback: false)
        self.captureBrowserSource = d.bool("captureBrowserSource", fallback: true)
        self.appearanceStyle = d.string(forKey: "appearanceStyle") ?? "auto"
        self.panelWidth = d.double("panelWidth", fallback: 640)
        self.autoUnfoldLines = max(0, d.int("autoUnfoldLines", fallback: 4))
        self.editorApp = d.string(forKey: "editorApp") ?? ""
        self.keymapOverrides = (d.dictionary(forKey: "keymapOverrides") as? [String: String]) ?? [:]
        self.ocrLanguages = d.stringArray("ocrLanguages") ?? Self.defaultOCRLanguages
        self.onboardingCompleted = d.bool("firstRunDone", fallback: false)
        self.blurCloseEnabled = d.bool("blurCloseEnabled", fallback: true)
        self.blurCloseDelay = d.double("blurCloseDelay", fallback: 0.35)
        self.launchAtLogin = d.bool("launchAtLogin", fallback: false)
    }

    static let defaultOCRLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    // MARK: 派生

    var retentionSeconds: TimeInterval {
        switch retentionPreset {
        case "7d": return 7 * 86400
        case "30d": return 30 * 86400
        case "forever": return 365 * 100 * 86400
        default: return 24 * 86400
        }
    }

    var hotkeyModifiers: HotkeyCenter.Modifiers {
        HotkeyCenter.Modifiers(rawValue: hotkeyModifiersRaw)
    }

    /// 人类可读的热键摘要，如「⇧⌘V」（⌃⌥⇧⌘，与系统菜单一致）
    var hotkeySummary: String {
        var s = ""
        let m = hotkeyModifiersRaw
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey) != 0 { s += "⌥" }
        if m & UInt32(shiftKey) != 0 { s += "⇧" }
        if m & UInt32(cmdKey) != 0 { s += "⌘" }
        if let c = Self.keyChar(for: hotkeyKeyCode) { s += c }
        return s.isEmpty ? "—" : s
    }

    private static let keyChars: [UInt32: String] = [
        0x00: "A", 0x06: "Z", 0x08: "C", 0x09: "V", 0x0C: "Q", 0x0D: "W",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x19: "9", 0x1A: "7", 0x1C: "8",
    ]
    private static func keyChar(for code: UInt32) -> String? { keyChars[code] }

    // MARK: 开机自启

    private func applyLaunchAtLogin() {
        if #available(macOS 13, *) {
            let service = SMAppService.mainApp
            do {
                if launchAtLogin { try service.register() }
                else { try service.unregister() }
            } catch {
                FileHandle.standardError.write("launchAtLogin: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    private func notify(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

private extension UserDefaults {
    func uint32(_ key: String, fallback: UInt32) -> UInt32 {
        guard let v = object(forKey: key) else { return fallback }
        return (v as? NSNumber)?.uint32Value ?? fallback
    }
    func int(_ key: String, fallback: Int) -> Int {
        guard let v = object(forKey: key) else { return fallback }
        return (v as? NSNumber)?.intValue ?? fallback
    }
    func double(_ key: String, fallback: Double) -> Double {
        guard let v = object(forKey: key) else { return fallback }
        return (v as? NSNumber)?.doubleValue ?? fallback
    }
    func bool(_ key: String, fallback: Bool) -> Bool {
        guard object(forKey: key) != nil else { return fallback }
        return bool(forKey: key)
    }
    func stringArray(_ key: String) -> [String]? {
        object(forKey: key) as? [String]
    }
}
