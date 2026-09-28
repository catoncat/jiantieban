import AppKit
import ApplicationServices
import Core

/// 剪贴板没有原生来源字段：异步读取复制时前台浏览器的普通页面，作为「可能来自」的线索。
/// Chrome 用 Apple Events 检查窗口模式；Helium 没有脚本字典，用辅助功能读取焦点网页。
enum BrowserSourceCapture {
    @MainActor
    static func capture(bundleID: String, pid: pid_t, _ completion: @escaping @MainActor @Sendable (BrowserSource?) -> Void) {
        Task.detached(priority: .utility) {
            let source: BrowserSource?
            switch bundleID {
            case "com.google.Chrome": source = readChrome()
            case "net.imput.helium": source = readHelium(pid: pid)
            default: source = nil
            }
            await completion(source)
        }
    }

    private static func source(bundleID: String, title: String, rawURL: String) -> BrowserSource? {
        guard rawURL.count <= 4096,
              let url = URLComponents(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        let cleanTitle = String(title.prefix(200)).components(separatedBy: .newlines).joined(separator: " ")
        return BrowserSource(bundleID: bundleID, title: cleanTitle, url: rawURL)
    }

    private static func readChrome() -> BrowserSource? {
        let script = NSAppleScript(source: """
            tell application id "com.google.Chrome"
                if (count of windows) is 0 then return {"", ""}
                set frontWindow to front window
                if (mode of frontWindow) is not "normal" then return {"", ""}
                set frontTab to active tab of frontWindow
                return {URL of frontTab, title of frontTab}
            end tell
            """)
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error),
              result.numberOfItems == 2,
              let url = result.atIndex(1)?.stringValue,
              let title = result.atIndex(2)?.stringValue else { return nil }
        return source(bundleID: "com.google.Chrome", title: title, rawURL: url)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func readHelium(pid: pid_t) -> BrowserSource? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let windowRef = attribute(app, kAXFocusedWindowAttribute),
              let focusedRef = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(windowRef) == AXUIElementGetTypeID(),
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        guard !isPrivate(window) else { return nil }
        var current: AXUIElement? = .some(focusedRef as! AXUIElement)
        for _ in 0..<16 {
            guard let element = current else { break }
            if attribute(element, kAXRoleAttribute) as? String == "AXWebArea",
               let url = attribute(element, "AXURL") as? URL,
               let title = attribute(element, kAXTitleAttribute) as? String {
                return source(bundleID: "net.imput.helium", title: title, rawURL: url.absoluteString)
            }
            if let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                current = .some(parent as! AXUIElement)
            } else {
                current = nil
            }
        }
        return nil
    }

    /// Chromium 的无痕/访客标记通常出现在窗口标题或工具栏标签；具体形态仍需真机验收。
    private static func isPrivate(_ window: AXUIElement) -> Bool {
        let markers = ["incognito", "private", "guest", "无痕", "隐私"]
        var scanned = 0
        func scan(_ element: AXUIElement, depth: Int) -> Bool {
            guard scanned < 200, depth < 9 else { return false }
            scanned += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXWindow" || role == "AXButton" || role == "AXStaticText" {
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    if let text = attribute(element, key) as? String,
                       markers.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return true }
                }
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if scan(child, depth: depth + 1) { return true }
            }
            return false
        }
        return scan(window, depth: 0)
    }
}
