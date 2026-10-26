import Foundation

/// Posting an event is observable; whether the receiving app inserts it is not.
public enum HeadlessPasteExecutionResult: String, Equatable, Sendable {
    case eventSent = "event_sent"
}

/// A bounded, synchronous paste transaction. It never activates an app, opens UI,
/// requests permissions, or leaves a callback behind when the caller exits.
@MainActor
public final class HeadlessPasteExecutor {
    private let permission: PastebackPermissionChecking
    private let clipboard: PastebackClipboardWriting
    private let targetIsCurrent: () -> Bool
    private let modifiersReleased: () -> Bool
    private let sendCommandV: () -> Bool
    private let now: () -> TimeInterval
    private let wait: (TimeInterval) -> Void

    public init(
        permission: PastebackPermissionChecking,
        clipboard: PastebackClipboardWriting,
        targetIsCurrent: @escaping () -> Bool,
        modifiersReleased: @escaping () -> Bool,
        sendCommandV: @escaping () -> Bool,
        now: @escaping () -> TimeInterval,
        wait: @escaping (TimeInterval) -> Void
    ) {
        self.permission = permission
        self.clipboard = clipboard
        self.targetIsCurrent = targetIsCurrent
        self.modifiersReleased = modifiersReleased
        self.sendCommandV = sendCommandV
        self.now = now
        self.wait = wait
    }

    public func execute(
        _ content: PastebackContent,
        expectedClipboardChangeCount: Int? = nil,
        modifierTimeout: TimeInterval = 2
    ) throws -> HeadlessPasteExecutionResult {
        let initialChangeCount = expectedClipboardChangeCount ?? clipboard.changeCount
        let deadline = now() + max(0, modifierTimeout)
        try validate(changeCount: initialChangeCount)
        while !modifiersReleased() {
            try validate(changeCount: initialChangeCount)
            guard now() < deadline else {
                throw HeadlessPasteError(code: "modifiers_timeout", message: "Modifier keys were not released before the paste timeout.")
            }
            wait(min(0.01, max(0, deadline - now())))
        }
        try validate(changeCount: initialChangeCount)
        guard clipboard.write(content) else {
            throw HeadlessPasteError(code: "content_unavailable", message: "The clipboard content could not be written.", clipboardChanged: clipboard.changeCount != initialChangeCount)
        }
        let writtenChangeCount = clipboard.changeCount
        // Keep the process alive while pasteboard ownership settles, unlike the
        // panel coordinator's asynchronous callback. Never paste a newer copy.
        wait(0.05)
        try validate(changeCount: writtenChangeCount, clipboardChanged: true)
        guard modifiersReleased() else {
            throw HeadlessPasteError(code: "modifiers_changed", message: "Modifier keys changed before the paste event could be sent.", clipboardChanged: true)
        }
        guard sendCommandV() else {
            throw HeadlessPasteError(code: "event_unavailable", message: "The paste key events could not be created or sent.", clipboardChanged: true)
        }
        return .eventSent
    }

    private func validate(changeCount: Int, clipboardChanged: Bool = false) throws {
        guard permission.isTrusted else {
            throw HeadlessPasteError(code: "accessibility_required", message: "Accessibility permission is required for this process; no permission dialog was opened.", clipboardChanged: clipboardChanged)
        }
        guard targetIsCurrent() else {
            throw HeadlessPasteError(code: "target_changed", message: "The original foreground application is no longer active.", clipboardChanged: clipboardChanged)
        }
        guard clipboard.changeCount == changeCount else {
            throw HeadlessPasteError(code: "clipboard_changed", message: "The clipboard changed during this paste request; no paste event was sent.", clipboardChanged: clipboardChanged)
        }
    }
}
