import AppKit
import Core
import PastebackPlatform

@MainActor
enum Pasteback {
    static func makeCoordinator() -> PastebackCoordinator {
        PastebackCoordinator(
            permission: SystemAccessibilityPermission(),
            clipboard: SystemPastebackClipboard(),
            sender: SystemPasteCommandSender(),
            scheduler: MainQueuePasteScheduler()
        )
    }

    static func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class SystemAccessibilityPermission: PastebackPermissionChecking {
    var isTrusted: Bool { AXIsProcessTrusted() }
}


@MainActor
private final class MainQueuePasteScheduler: PastebackScheduling {
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: action)
    }
}

@MainActor
private final class SystemPasteCommandSender: PastebackCommandSending {
    func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
