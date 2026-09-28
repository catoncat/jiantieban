import AppKit
import Combine
import Core

/// 设置 → 快捷键：录一个面板动作的新快捷键。同一时间只录一个。
/// 录制中所有按键都被吃掉（包括 ⌘Q、⌘W），Esc 取消，⌫ 清除；不合规的组合给出原因、继续录。
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: PanelAction?
    /// 表格下面的一句话：为什么这个组合不行 / 哪个动作被换走了快捷键
    @Published var note: String?
    private var monitor: Any?

    func start(_ action: PanelAction) {
        stop()
        recording = action
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            self.handle(event, for: action)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func handle(_ event: NSEvent, for action: PanelAction) {
        let settings = AppSettings.shared
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty { // Esc
            stop()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, modifiers.isEmpty { // ⌫ / ⌦
            settings.keymap = settings.keymap.overriding([action: KeyCombo?.none])
            note = "已清除「\(action.title)」的快捷键；需要时可恢复默认"
            stop()
            return
        }
        guard let combo = KeyTranslation.combo(for: event) else {
            NSSound.beep()
            return
        }
        // 对比真实硬件键码：唤醒热键可录任意键，不能靠有限的字符表反推。
        let isWakeHotkey = UInt32(event.keyCode) == settings.hotkeyKeyCode &&
            KeyTranslation.carbonModifiers(for: event.modifierFlags) == settings.hotkeyModifiersRaw
        let reserved = isWakeHotkey ? [combo: "唤醒面板的热键"] : [:]
        if let problem = Keymap.problem(with: combo, reserved: reserved) {
            note = problem + "，换一个试试"
            NSSound.beep()
            return
        }
        let before = settings.keymap
        let displaced = before.bindings.first { $0.value == combo && $0.key != action }?.key
        settings.keymap = before.overriding([action: combo])
        note = displaced.map { "\(combo.display) 原来是「\($0.title)」的，已改给「\(action.title)」；「\($0.title)」现在没有快捷键" }
        stop()
    }
}
