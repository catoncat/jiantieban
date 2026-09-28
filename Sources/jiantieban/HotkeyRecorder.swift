import AppKit
import Combine

/// 热键录制状态，供设置页显示“正在录制”。
@MainActor
final class HotkeyRecorderModel: ObservableObject {
    @Published var isRecording = false
}

/// 录制下一个带修饰键的按键组合，写入 AppSettings。
@MainActor
final class HotkeyRecorder {
    static let shared = HotkeyRecorder()

    let model = HotkeyRecorderModel()
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        model.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else { return event }
            self.stop()
            AppSettings.shared.hotkeyModifiersRaw = KeyTranslation.carbonModifiers(for: modifiers)
            AppSettings.shared.hotkeyKeyCode = UInt32(event.keyCode)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        model.isRecording = false
    }
}
