import Foundation

/// A history selector, independent of panels, hotkeys, or the calling program.
public enum HeadlessPasteSelector: Equatable, Sendable {
    case id(Int64)
    case latest
}

public enum HeadlessPasteFormat: String, Equatable, Sendable {
    case `default`
    case plain
    case original

    public func usesPlainText(defaultPlainText: Bool) -> Bool {
        switch self {
        case .default: return defaultPlainText
        case .plain: return true
        case .original: return false
        }
    }
}

/// Stable error codes are suitable for callers; messages contain no clipboard content.
public struct HeadlessPasteError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public let exitCode: Int32
    public let clipboardChanged: Bool

    public init(code: String, message: String, exitCode: Int32 = 1, clipboardChanged: Bool = false) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
        self.clipboardChanged = clipboardChanged
    }

    public var errorDescription: String? { message }
}

public struct HeadlessPasteRequest: Equatable, Sendable {
    public let selector: HeadlessPasteSelector
    public let format: HeadlessPasteFormat

    public init(selector: HeadlessPasteSelector, format: HeadlessPasteFormat = .default) {
        self.selector = selector
        self.format = format
    }

    /// Arguments after `paste`. Require exactly one selector; never silently paste a default row.
    public static func parse(_ arguments: [String]) throws -> HeadlessPasteRequest {
        var selector: HeadlessPasteSelector?
        var format: HeadlessPasteFormat?
        var index = 0
        func invalid(_ message: String) -> HeadlessPasteError {
            HeadlessPasteError(code: "invalid_arguments", message: message, exitCode: 2)
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--latest":
                guard selector == nil else { throw invalid("Specify exactly one history selector: <id> or --latest.") }
                selector = .latest
            case "--format":
                guard format == nil else { throw invalid("--format may only be specified once.") }
                index += 1
                guard index < arguments.count,
                      let value = HeadlessPasteFormat(rawValue: arguments[index]) else {
                    throw invalid("--format requires default, plain, or original.")
                }
                format = value
            default:
                guard selector == nil,
                      !argument.isEmpty,
                      argument.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let id = Int64(argument), id > 0 else {
                    throw invalid("Expected a positive history id, --latest, or --format default|plain|original.")
                }
                selector = .id(id)
            }
            index += 1
        }
        guard let selector else { throw invalid("A history selector is required: <id> or --latest.") }
        return HeadlessPasteRequest(selector: selector, format: format ?? .default)
    }

    /// Resolves persisted history only. Clipboard capture belongs to the monitor, not selection:
    /// re-ingesting the system clipboard here could resurrect old contents or bypass privacy rules.
    @MainActor
    public func select(from store: ClipStore) throws -> ClipItem {
        let item: ClipItem?
        switch selector {
        case .id(let id): item = try store.item(id: id)
        case .latest: item = try store.latestItem()
        }
        guard let item else {
            throw HeadlessPasteError(code: "item_not_found", message: "No matching clipboard history record exists.")
        }
        guard ItemActions.can(.paste, item) else {
            throw HeadlessPasteError(code: "content_unavailable", message: "This clipboard record cannot be pasted.")
        }
        return item
    }

    /// Uses the same safe payloads as panel paste. Formatting is not secret resolution:
    /// a reference record always remains a reference, including `--format plain`.
    public func content(for item: ClipItem, defaultPlainText: Bool, imageAsFile: Bool) throws -> PastebackContent {
        guard ItemActions.can(.paste, item) else {
            throw HeadlessPasteError(code: "content_unavailable", message: "This clipboard record cannot be pasted.")
        }
        if item.isSecret {
            guard let token = item.secretToken, !token.isEmpty else {
                throw HeadlessPasteError(code: "content_unavailable", message: "The clipboard reference is unavailable.")
            }
            return .secretReference(token)
        }
        switch item.kind {
        case .text:
            // History currently stores only the plain representation. Explicit preservation
            // must not pretend that discarded RTF/HTML can be recovered. The default keeps
            // the panel's existing fallback, even when plainTextPaste is disabled.
            guard format != .original else {
                throw HeadlessPasteError(code: "format_unavailable", message: "Original text formatting is not retained in clipboard history; use default or plain.")
            }
            return .text(item.content)
        case .image:
            guard format != .plain else {
                throw HeadlessPasteError(code: "format_unavailable", message: "An image record has no plain-text paste representation.")
            }
            guard let path = item.imagePath, !path.isEmpty else {
                throw HeadlessPasteError(code: "content_unavailable", message: "The clipboard image is unavailable.")
            }
            return .image(path: path, asFile: format == .original ? false : imageAsFile)
        }
    }
}
