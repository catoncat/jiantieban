import AppKit
import Core

@MainActor
public final class SystemPastebackClipboard: PastebackClipboardWriting {
    private let pasteboard: NSPasteboard
    private let fileManager: FileManager

    public init(
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default
    ) {
        self.pasteboard = pasteboard
        self.fileManager = fileManager
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func write(_ content: PastebackContent) -> Bool {
        guard let object = preparedObject(for: content) else { return false }
        let original = snapshot()

        pasteboard.clearContents()
        let wroteContent: Bool
        switch object {
        case let .string(value):
            wroteContent = pasteboard.setString(value, forType: .string)
        case let .object(value):
            wroteContent = pasteboard.writeObjects([value])
        }

        guard wroteContent,
              pasteboard.setString("1", forType: PasteboardMarker.selfType) else {
            restore(original)
            return false
        }
        return true
    }

    private enum PreparedObject {
        case string(String)
        case object(NSPasteboardWriting)
    }

    private func preparedObject(for content: PastebackContent) -> PreparedObject? {
        switch content {
        case let .text(text), let .secretReference(text), let .secretPlaintext(text):
            return .string(text)
        case let .image(path, asFile):
            guard fileManager.fileExists(atPath: path),
                  fileManager.isReadableFile(atPath: path) else { return nil }
            if asFile {
                return .object(NSURL(fileURLWithPath: path))
            }
            guard let image = NSImage(contentsOfFile: path) else { return nil }
            return .object(image)
        }
    }

    private func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    }
}
