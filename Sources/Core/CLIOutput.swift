import Foundation

/// Explicit public metadata, not a dump of an internal model or jt plaintext.
public struct CLIRecord: Encodable, Sendable {
    public let id: String
    public let kind: String
    public let content: String
    public let image_path: String?
    public let thumb_path: String?
    public let ocr_text: String?
    public let is_favorite: Bool
    public let was_pasted: Bool
    public let is_secret: Bool
    public let secret_token: String?
    public let secret_name: String?
    public let masked_preview: String?
    public let secret_missing: Bool
    public let last_copied_at: String
    public let created_at: String
    public let source: CLISource?
    public init(_ item: ClipItem) {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        id = String(item.id); kind = item.kind.rawValue
        // Defense in depth: even a malformed reference row must never expose stale value data.
        content = item.isSecret ? (item.secretToken ?? "") : item.content
        image_path = item.isSecret ? nil : item.imagePath
        thumb_path = item.isSecret ? nil : item.thumbPath
        ocr_text = item.isSecret ? nil : item.ocrText
        is_favorite = item.isFavorite; was_pasted = item.wasPasted
        is_secret = item.isSecret; secret_token = item.secretToken
        secret_name = item.secretName; masked_preview = item.maskedPreview
        secret_missing = item.secretMissing
        last_copied_at = dates.string(from: item.lastCopiedAt)
        created_at = dates.string(from: item.createdAt)
        source = item.isSecret ? nil : item.browserSource.map(CLISource.init)
    }
}


/// Mutation acknowledgments deliberately omit content, references, paths and source metadata.
public struct CLIMutationRecord: Encodable, Sendable {
    public let id: String
    public let kind: String
    public let is_favorite: Bool
    public let is_secret: Bool
    public let was_pasted: Bool
    public init(_ item: ClipItem) {
        id = String(item.id); kind = item.kind.rawValue
        is_favorite = item.isFavorite; is_secret = item.isSecret; was_pasted = item.wasPasted
    }
}

public struct CLISource: Encodable, Sendable {
    public let bundle_id: String
    public let title: String
    public let url: String
    public init(_ source: BrowserSource) { bundle_id = source.bundleID; title = source.title; url = source.url }
}

public enum CLIOutput {
    public static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    public static func success(command: String, result: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "ok": true, "command": command, "result": result], options: [.sortedKeys])
    }
    public static func failure(command: String, code: String, message: String, clipboardChanged: Bool? = nil) -> Data {
        var object: [String: Any] = ["schema_version": 1, "ok": false, "command": command, "code": code, "message": message]
        if let clipboardChanged { object["clipboard_changed"] = clipboardChanged }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
