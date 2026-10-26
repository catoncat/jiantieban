import AppKit
import Core
import CryptoKit
import Darwin
import PastebackPlatform

/// A synchronous CLI entry point: no NSApplication, panel, activation, permission prompt,
/// or work scheduled beyond the lifetime of this process.
@MainActor
enum HeadlessPasteCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let request = try HeadlessPasteRequest.parse(arguments)
            let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let settings = AppSettings.shared
            let directory = dataDir()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = open(directory.appendingPathComponent("paste.lock").path,
                            O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard lock >= 0 else {
                throw HeadlessPasteError(code: "lock_unavailable", message: "Cannot open paste process lock.")
            }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw HeadlessPasteError(code: "paste_busy", message: "Another paste request is in progress.")
            }
            defer { flock(lock, LOCK_UN) }
            let store = try ClipStore(path: directory.appendingPathComponent("jiantieban.db").path,
                config: StoreConfig(retentionSeconds: settings.retentionSeconds,
                    hardLimit: settings.hardLimit, maxSaveLength: settings.maxSaveLength,
                    favoritesPermanent: settings.favoritesPermanent))
            let source = SystemPasteboard()
            let initialCount = source.changeCount
            var item: ClipItem
            if request.selector == .latest {
                // Do not ingest here: doing so would bypass privacy, resurrect deleted records,
                // race the app's monitor, and lose source metadata. Wait for its committed record.
                let snapshot = source.snapshot()
                guard source.changeCount == initialCount else {
                    throw HeadlessPasteError(code: "clipboard_changed", message: "Clipboard changed while selecting history.")
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 1.2
                while true {
                    guard source.changeCount == initialCount else {
                        throw HeadlessPasteError(code: "clipboard_changed", message: "Clipboard changed while waiting for history.")
                    }
                    if let latest = try store.latestItem(), matches(snapshot, item: latest, maxSaveLength: settings.maxSaveLength) {
                        item = latest
                        break
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        let code = try store.latestItem() == nil ? "history_empty" : "history_not_current"
                        throw HeadlessPasteError(code: code,
                            message: "Latest history is not current. Run the app/monitor and allow capture, or select a record ID explicitly. Privacy exclusions are not bypassed.")
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            } else {
                item = try request.select(from: store)
            }
            let content = try request.content(for: item,
                defaultPlainText: settings.plainTextPaste, imageAsFile: settings.imagePasteAsFile)
            let clipboard = SystemPastebackClipboard()
            let executor = HeadlessPasteExecutor(
                permission: HeadlessPermission(), clipboard: clipboard,
                targetIsCurrent: {
                    guard let targetPID, targetPID != ProcessInfo.processInfo.processIdentifier else { return false }
                    return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
                },
                modifiersReleased: {
                    let flags = CGEventSource.flagsState(.combinedSessionState)
                    return flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty
                },
                sendCommandV: {
                    guard let source = CGEventSource(stateID: .hidSystemState),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                    return true
                },
                now: { ProcessInfo.processInfo.systemUptime },
                wait: { Thread.sleep(forTimeInterval: $0) })
            _ = try executor.execute(content, expectedClipboardChangeCount: initialCount)
            // Event delivery cannot prove that another app accepted the paste. A retention
            // failure after dispatch must never become a retryable paste failure.
            var retained = true
            do { try store.markPasted(id: item.id, expectedItem: item) } catch { retained = false }
            output(["ok": true, "status": "event_sent", "id": item.id,
                    "format": actualFormat(content), "retained": retained,
                    "clipboard_changed": true], to: .standardOutput)
            return 0
        } catch let error as HeadlessPasteError {
            output(["ok": false, "code": error.code, "message": error.message,
                    "clipboard_changed": error.clipboardChanged], to: .standardError)
            return error.exitCode
        } catch {
            output(["ok": false, "code": "storage_error", "message": error.localizedDescription,
                    "clipboard_changed": false], to: .standardError)
            return 1
        }
    }

    private static func matches(_ snapshot: PasteboardSnapshot, item: ClipItem, maxSaveLength: Int) -> Bool {
        // A self-marked clipboard represents a prior paste, not a new copy to ingest.
        if snapshot.hasSelfMarker { return true }
        if let png = snapshot.imagePNG {
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            return item.kind == .image && item.imageHash == hash
        }
        if let text = snapshot.text, !text.isEmpty {
            return item.kind == .text && item.content == String(text.prefix(max(0, maxSaveLength)))
        }
        // Empty/unsupported pasteboards have no new supported record to await.
        return true
    }

    private static func actualFormat(_ content: PastebackContent) -> String {
        switch content {
        case .text: return "plain"
        case .secretReference: return "reference"
        case .secretPlaintext: return "plain"
        case let .image(_, asFile): return asFile ? "file" : "image"
        }
    }

    private static func output(_ value: [String: Any], to handle: FileHandle) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            handle.write(data)
            handle.write(Data([0x0a]))
        }
    }
}

@MainActor
private final class HeadlessPermission: PastebackPermissionChecking {
    var isTrusted: Bool { AXIsProcessTrusted() }
}
