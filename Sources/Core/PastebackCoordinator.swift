import Foundation

public enum PastebackContent: Equatable, Sendable {
    case text(String)
    case image(path: String, asFile: Bool)
    case secretReference(String)
    case secretPlaintext(String)
}

public enum PastebackIntent: Equatable, Sendable {
    case automaticPaste
    case copyOnly
}

public enum PastebackResult: Equatable, Sendable {
    case pasted
    case copied
    case needsAccessibility
    case secretPlaintextConfirmationRequired
    case contentUnavailable

    /// 复制密钥引用必须留下面板（VoiceOver / CUA 不能在成功路径上丢窗）。
    /// 真正贴回（`.pasted`）仍关窗，好让随后的 ⌘V 落到前台 App。
    public func hidesPanel(for content: PastebackContent?) -> Bool {
        switch self {
        case .pasted:
            return true
        case .copied:
            if case .secretReference? = content { return false }
            return true
        case .needsAccessibility, .secretPlaintextConfirmationRequired, .contentUnavailable:
            return false
        }
    }
}

@MainActor
public protocol PastebackPermissionChecking: AnyObject {
    var isTrusted: Bool { get }
}

@MainActor
public protocol PastebackClipboardWriting: AnyObject {
    /// Changes whenever clipboard ownership/content changes, including external copies.
    var changeCount: Int { get }
    func write(_ content: PastebackContent) -> Bool
}

@MainActor
public protocol PastebackCommandSending: AnyObject {
    func sendCommandV()
}

@MainActor
public protocol PastebackScheduling: AnyObject {
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
public final class PastebackCoordinator {
    private let permission: PastebackPermissionChecking
    private let clipboard: PastebackClipboardWriting
    private let sender: PastebackCommandSending
    private let scheduler: PastebackScheduling

    public init(
        permission: PastebackPermissionChecking,
        clipboard: PastebackClipboardWriting,
        sender: PastebackCommandSending,
        scheduler: PastebackScheduling
    ) {
        self.permission = permission
        self.clipboard = clipboard
        self.sender = sender
        self.scheduler = scheduler
    }

    public var mode: PastebackIntent {
        permission.isTrusted ? .automaticPaste : .copyOnly
    }

    @discardableResult
    public func execute(
        _ content: PastebackContent,
        intent: PastebackIntent,
        secretPlaintextConfirmed: Bool = false,
        onPaste: (@MainActor @Sendable () -> Void)? = nil
    ) -> PastebackResult {
        if intent == .automaticPaste && !permission.isTrusted {
            return .needsAccessibility
        }
        if case .secretPlaintext = content,
           intent == .copyOnly,
           !secretPlaintextConfirmed {
            return .secretPlaintextConfirmationRequired
        }
        guard clipboard.write(content) else {
            return .contentUnavailable
        }
        guard intent == .automaticPaste else {
            return .copied
        }
        let writtenChangeCount = clipboard.changeCount
        scheduler.schedule { [clipboard, sender] in
            // A later copy must not be pasted or attributed to this older request.
            guard clipboard.changeCount == writtenChangeCount else { return }
            sender.sendCommandV()
            onPaste?()
        }
        return .pasted
    }
}
