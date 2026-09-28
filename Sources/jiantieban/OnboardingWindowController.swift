import AppKit
import SwiftUI

/// 首启引导窗口：欢迎 → 权限说明 → 完成。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = OnboardingModel()
    private let onFinish: () -> Void
    private var didFinish = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        model.accessibilityTrusted = AXIsProcessTrusted()
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "jiantieban"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = OnboardingView(
            model: model,
            onStart: { [weak self] in
                self?.model.page = .permission
            },
            onOpenSettings: { [weak self] in
                self?.openAccessibilitySettings()
            },
            onLater: { [weak self] in
                self?.finish()
            }
        )
        window.contentView = NSHostingController(rootView: rootView).view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func openAccessibilitySettings() {
        model.didRequestAccessibility = true
        Pasteback.requestAccessibility()
        refreshAccessibilityStatus()
    }

    func refreshAccessibilityStatus() {
        model.accessibilityTrusted = AXIsProcessTrusted()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onFinish()
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        // 用户直接关窗也视为完成首启，避免每次启动都弹。
        finish()
    }
}
