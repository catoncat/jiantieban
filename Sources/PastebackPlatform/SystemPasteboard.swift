import AppKit
import Core

/// 自家写回 pasteboard 时打的标记类型，Monitor 见到即忽略（Maccy `.fromMaccy` 同款机制）。
public enum PasteboardMarker {
    public static let selfType = NSPasteboard.PasteboardType("rs.jiantieban.self")
}

/// 读系统剪贴板（ClipboardMonitor 轮询用）。
@MainActor
public final class SystemPasteboard: PasteboardReading {
    private let pasteboard = NSPasteboard.general

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> PasteboardSnapshot {
        var snap = PasteboardSnapshot(changeCount: pasteboard.changeCount)
        let types = Set(pasteboard.types ?? [])
        snap.hasSelfMarker = types.contains(PasteboardMarker.selfType)

        // 优先级：先图片后文本
        if types.contains(.tiff) || types.contains(.png),
           let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            snap.imagePNG = png
            return snap
        }
        snap.text = pasteboard.string(forType: .string)
        return snap
    }
}
