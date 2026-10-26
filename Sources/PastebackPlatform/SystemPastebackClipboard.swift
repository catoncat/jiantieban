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

    #if DEBUG
    // Deterministic race injection for the platform test executable only.
    public var testingBeforeClear: (() -> Void)?
    public var testingAfterContentWrite: (() -> Void)?
    #endif

    public func write(_ content: PastebackContent) -> Bool {
        let originalChangeCount = pasteboard.changeCount
        guard let object = preparedObject(for: content) else { return false }
        let original = snapshot()

        #if DEBUG
        testingBeforeClear?()
        #endif
        // Loading image bytes or lazy pasteboard providers can take time. Never
        // overwrite a copy made since this write began.
        guard pasteboard.changeCount == originalChangeCount else { return false }
        let ownedChangeCount = pasteboard.clearContents()
        let wroteContent: Bool
        switch object {
        case let .string(value, type):
            wroteContent = pasteboard.setString(value, forType: type)
        case let .data(value, type):
            wroteContent = pasteboard.setData(value, forType: type)
        }

        #if DEBUG
        testingAfterContentWrite?()
        #endif
        // Do not attach our self marker to another application's newer copy.
        guard pasteboard.changeCount == ownedChangeCount else { return false }
        guard wroteContent,
              pasteboard.setString("1", forType: PasteboardMarker.selfType) else {
            restore(original, ifOwnedChangeCount: ownedChangeCount)
            return false
        }
        return pasteboard.changeCount == ownedChangeCount
    }

    private enum PreparedObject {
        case string(String, NSPasteboard.PasteboardType)
        case data(Data, NSPasteboard.PasteboardType)
    }

    private func preparedObject(for content: PastebackContent) -> PreparedObject? {
        switch content {
        case let .text(text), let .secretReference(text), let .secretPlaintext(text):
            return .string(text, .string)
        case let .image(path, asFile):
            guard fileManager.fileExists(atPath: path),
                  fileManager.isReadableFile(atPath: path) else { return nil }
            if asFile {
                return .string(URL(fileURLWithPath: path).absoluteString, .fileURL)
            }
            // Materialize bytes before mutation. No lazy NSImage provider may
            // depend on the short-lived CLI process remaining alive.
            guard let image = NSImage(contentsOfFile: path),
                  let tiff = image.tiffRepresentation else { return nil }
            return .data(tiff, .tiff)
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

    private func restore(_ items: [NSPasteboardItem], ifOwnedChangeCount: Int) {
        // Rollback is best effort, never an excuse to erase a newer copy.
        guard pasteboard.changeCount == ifOwnedChangeCount else { return }
        pasteboard.clearContents()
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    }
}

