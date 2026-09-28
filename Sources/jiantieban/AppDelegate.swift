import AppKit
import Carbon.HIToolbox
import Core
import PastebackPlatform
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pipeline: IngestPipeline!
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private var store: ClipStore?
    private let hotkeys = HotkeyCenter()
    private let settings = AppSettings.shared
    private let statusItem = StatusItemController()
    private var hotkeyID: UInt32 = 0
    private var settingsWindow: NSWindow?
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        do {
            let (store, pipeline, secrets) = try makeEngine()
            self.store = store
            self.pipeline = pipeline
            self.pipeline.policy = IngestPolicy(
                privacyMode: settings.privacyMode,
                autoExcludeSecrets: settings.autoExcludeSecrets
            )
            panel = PanelController(store: store, secrets: secrets)
            panel.onOpenSettings = { [weak self] in self?.openSettings() }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        monitor = ClipboardMonitor(pasteboard: SystemPasteboard()) { [weak self] snapshot in
            guard let self else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication
            let item = self.pipeline.handle(snapshot)
            self.panel.refreshIfVisible()
            guard self.settings.captureBrowserSource,
                  let frontmost, let bundleID = frontmost.bundleIdentifier,
                  ["com.google.Chrome", "net.imput.helium"].contains(bundleID), let item else { return }
            BrowserSourceCapture.capture(bundleID: bundleID, pid: frontmost.processIdentifier) { [weak self] source in
                guard let self, let source else { return }
                do {
                    if try self.store?.setBrowserSource(source, forItemID: item.id, copiedAt: item.lastCopiedAt) == true {
                        self.panel.refreshIfVisible()
                    }
                } catch {
                    NSLog("[jtb] browser source save failed: \(error)")
                }
            }
        }
        // 截图实例只读自己的隔离库，不监听系统剪贴板，也不占用真实 App 的全局热键。
        if !DebugFlags.showPanelOnLaunch {
            monitor.start()
            reconfigureHotkey()
        }

        statusItem.onShowPanel = { [weak self] in self?.showPanel() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onRequestAccessibility = {
            Pasteback.requestAccessibility()
        }
        statusItem.onClearHistory = { [weak self] in
            self?.clearHistory()
        }
        statusItem.onQuit = { NSApp.terminate(nil) }
        if !DebugFlags.showPanelOnLaunch {
            statusItem.install()
            statusItem.refreshAccessibilityStatus()
        }

        if !settings.onboardingCompleted && !DebugFlags.showPanelOnLaunch {
            let controller = OnboardingWindowController { [weak self] in
                self?.settings.onboardingCompleted = true
                self?.onboardingWindowController = nil
            }
            onboardingWindowController = controller
            controller.show()
        }

        observe(.jtbHotkeyChanged) { $0.reconfigureHotkey() }
        observe(.jtbPolicyChanged) { $0.applyPolicy() }
        observe(.jtbHistoryChanged) { $0.applyHistory() }
        observe(.jtbOCRLanguagesChanged) { $0.applyOCRLanguages() }
        observe(.jtbClearHistoryRequest) { $0.clearHistory() }

        print("jiantieban running — \(settings.hotkeySummary) to toggle panel")

        // 隐藏调试入口：jiantieban _debug-panel → 启动后立刻显示面板（截图/验收用）
        if DebugFlags.showPanelOnLaunch {
            panel.blurCloseEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.panel.show()
                if DebugFlags.autoScroll {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.panel.debugAutoScroll()
                    }
                }
            }
        }
    }

    /// 设置页的通知都投递在主队列；assumeIsolated 把"确实在主线程"告诉编译器（万一不在会直接断言，不会悄悄竞争）。
    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (AppDelegate) -> Void) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !DebugFlags.showPanelOnLaunch { statusItem.refreshAccessibilityStatus() }
        panel?.refreshPastebackMode()
        onboardingWindowController?.refreshAccessibilityStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        panel?.finishPendingDeletion()
    }

    // MARK: - 运行时配置同步

    private func reconfigureHotkey() {
        if hotkeyID != 0 { hotkeys.unregister(hotkeyID) }
        hotkeyID = hotkeys.register(modifiers: settings.hotkeyModifiers, keyCode: settings.hotkeyKeyCode) { [weak self] in
            guard let self else { return }
            if self.panel.isVisible { self.panel.hide() }
            else { self.showPanel() }
        }
    }

    private func applyPolicy() {
        pipeline.policy = IngestPolicy(
            privacyMode: settings.privacyMode,
            autoExcludeSecrets: settings.autoExcludeSecrets
        )
    }

    private func applyHistory() {
        store?.config.retentionSeconds = settings.retentionSeconds
        store?.config.hardLimit = settings.hardLimit
        store?.config.maxSaveLength = settings.maxSaveLength
        store?.config.favoritesPermanent = settings.favoritesPermanent
    }

    private func applyOCRLanguages() {
        pipeline.ocrLanguages = settings.ocrLanguages
    }

    private func clearHistory() {
        guard let store else { return }
        let files = (try? store.clear()) ?? []
        ImageStore.removeFiles(files)
    }

    /// 设置与面板只显示一个：面板是浮动层，若设置仍开着会被盖在后面。
    private func showPanel() {
        settingsWindow?.orderOut(nil)
        panel.show()
    }

    private func openSettings() {
        panel.hide(restoringPreviousApp: false)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "jiantieban 设置"
            window.contentView = NSHostingController(rootView: SettingsView()).view
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 主菜单（LSUIElement App 需要隐藏 Edit 菜单分发 Cmd+A/C/V/X/Z）

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }
}

@MainActor
func runApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // 无 Dock 图标
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}
