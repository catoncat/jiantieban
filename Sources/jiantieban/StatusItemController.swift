import AppKit

/// 菜单栏图标：剪切板管理器无 Dock（.accessory），必须靠状态栏图标提供
/// 常驻入口与设置/清空/退出的可达路径（否则设置页形同虚设）。
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private var accessibilityItem: NSMenuItem?

    var onShowPanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onQuit: (() -> Void)?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "jiantieban")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()
        let show = NSMenuItem(title: "显示面板", action: #selector(showPanel), keyEquivalent: "v")
        show.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(show)
        let accessibility = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibilityItem = accessibility
        menu.addItem(accessibility)
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "清空历史", action: #selector(clear), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 jiantieban", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    /// 刷新辅助功能状态行；在启动或授权变化后调用。
    func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilityItem?.title = trusted
            ? "一键贴回已启用"
            : "仅复制模式 · 启用一键贴回…"
        accessibilityItem?.isEnabled = !trusted
    }

    @objc private func showPanel() { onShowPanel?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func requestAccessibility() { onRequestAccessibility?() }
    @objc private func clear() {
        let alert = NSAlert()
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "此操作会删除所有历史记录和图片文件。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            onClearHistory?()
        }
    }
    @objc private func quit() { onQuit?() }
}
