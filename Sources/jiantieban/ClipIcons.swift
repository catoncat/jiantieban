import AppKit
import Core
import UniformTypeIdentifiers

/// 列表图标：只用系统 IconServices / CoreTypes 里的真素材。
/// 关键：请求 128pt 表现，再由 NSImageView 缩到 32pt。写成 32pt 会拿到 IconServices
/// 的简化灰模（空文档、空 PNG），那是顶替，不是 Spotlight 用的那套详细图标。
@MainActor
enum ClipIcons {
    static let sourcePointSize: CGFloat = 128

    private static let cache = NSCache<NSString, NSImage>()

    /// 剪贴板条目不是文件，不借文件图标：统一 SF Symbol 单色字形，同一列同一尺寸同一颜色。
    static func icon(for item: ClipItem) -> NSImage {
        switch item.kind {
        case .image:
            return symbol("photo")
        case .text:
            if item.isSecret { return symbol(item.secretMissing ? "lock.slash" : "lock.fill") }
            return icon(forText: item.content)
        }
    }

    static func icon(forText raw: String) -> NSImage {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return symbol("text.alignleft") }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "ftp", "vnc": return symbol("link")
            case "mailto": return symbol("envelope")
            case "file": return symbol("doc")
            default: break
            }
        }
        if isEmail(text) { return symbol("envelope") }
        if existingPath(in: text) != nil { return symbol("doc") }
        if typeFromFilename(text) != nil { return symbol("doc") }

        let head = String(text.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = head.lowercased()
        if head.hasPrefix("{") || head.hasPrefix("[") { return symbol("curlybraces") }
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.hasPrefix("<?xml") {
            return symbol("chevron.left.forwardslash.chevron.right")
        }
        if text.contains("\n"), text.split(separator: "\n").count > 3 { return symbol("text.alignleft") }
        return symbol("text.alignleft")
    }

    static func symbol(_ name: String) -> NSImage {
        let key = "sym:\(name)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - loaders

    static func uti(_ identifier: String) -> NSImage {
        let key = "uti:\(identifier)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let type = UTType(identifier) ?? .plainText
        let image = prepared(NSWorkspace.shared.icon(for: type))
        cache.setObject(image, forKey: key)
        return image
    }

    private static func prepared(_ source: NSImage) -> NSImage {
        let icon = source.copy() as? NSImage ?? source
        icon.isTemplate = false
        icon.size = NSSize(width: sourcePointSize, height: sourcePointSize)
        return icon
    }

    // MARK: - sniff

    private static func isEmail(_ text: String) -> Bool {
        guard !text.contains(" "), text.count < 254, text.contains("@"), text.contains(".") else {
            return false
        }
        let parts = text.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    private static func existingPath(in text: String) -> String? {
        var token = text
        if let nl = token.firstIndex(of: "\n") {
            token = String(token[..<nl])
        }
        if let semi = token.firstIndex(of: ";") {
            token = String(token[..<semi])
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        if token.hasPrefix("'"), token.hasSuffix("'"), token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        let expanded = (token as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) else {
            return nil
        }
        return expanded
    }

    private static func typeFromFilename(_ text: String) -> UTType? {
        guard !text.contains(" "), !text.contains("\n"), text.count < 180 else { return nil }
        let ext = (text as NSString).pathExtension.lowercased()
        guard (1...8).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return UTType(filenameExtension: ext)
    }
}
