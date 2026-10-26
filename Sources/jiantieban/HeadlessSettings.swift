import Core
import CoreFoundation
import Foundation

struct HeadlessSettingsError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Shared domain selection also isolates subprocess tests from the user's preferences.
enum PreferencesDomain {
    static var name: String {
        let override = ProcessInfo.processInfo.environment["JIANTIEBAN_PREFERENCES_SUITE"]
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? "rs.jiantieban"
    }

    static func defaults() -> UserDefaults? {
        let domain = name
        // Foundation rejects using the running app's own identifier as a suite.
        // Its standard defaults already use that domain; the standalone CLI still
        // needs an explicit suite to share preferences with the app.
        if domain == Bundle.main.bundleIdentifier { return .standard }
        return UserDefaults(suiteName: domain)
    }
}

/// Deliberately excludes security, permissions, launch-at-login and UI-only settings.
/// Existing processes cache their settings: writes take effect on their next launch.
@MainActor
enum HeadlessSettings {
    private enum ValueKind {
        case boolean
        case integer(ClosedRange<Int>)
        case choice([String])
        case languages
    }
    private struct Field {
        let kind: ValueKind
        let fallback: Any
    }
    private static let fields: [String: Field] = [
        "retentionPreset": Field(kind: .choice(["24h", "7d", "30d", "forever"]), fallback: "24h"),
        "hardLimit": Field(kind: .integer(100...5000), fallback: 600),
        "maxSaveLength": Field(kind: .integer(1000...50000), fallback: 12000),
        "favoritesPermanent": Field(kind: .boolean, fallback: true),
        "imagePasteAsFile": Field(kind: .boolean, fallback: false),
        "ocrLanguages": Field(kind: .languages, fallback: ["zh-Hans", "zh-Hant", "en-US"]),
    ]

    static func run(_ arguments: [String]) throws -> [String: Any] {
        guard let operation = arguments.first else {
            throw error("config requires get [key], set <key> <value>, or reset <key>")
        }
        guard let defaults = PreferencesDomain.defaults() else {
            throw CLIError("preferences_unavailable", "Cannot open preferences domain")
        }
        switch operation {
        case "get":
            guard arguments.count <= 2 else { throw error("config get accepts at most one key") }
            let keys: [String]
            if arguments.count == 2 {
                guard fields[arguments[1]] != nil else { throw error("Unsupported setting: \(arguments[1])") }
                keys = [arguments[1]]
            } else { keys = fields.keys.sorted() }
            var values: [String: Any] = [:]
            for key in keys {
                let field = fields[key]!
                // Invalid legacy values are not silently blessed as valid configuration.
                if let stored = defaults.object(forKey: key) {
                    do { values[key] = try validate(stored, field: field) }
                    catch {
                        throw CLIError("preferences_invalid", "Stored setting \(key) is invalid; use config reset \(key).")
                    }
                } else { values[key] = field.fallback }
            }
            return result(values, changed: false)
        case "set":
            guard arguments.count == 3 else { throw error("config set requires one key and one value") }
            let key = arguments[1]
            guard let field = fields[key] else { throw error("Unsupported setting: \(key)") }
            let raw = arguments[2]
            let decoded = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) ?? raw
            let value = try validate(decoded, field: field)
            defaults.set(value, forKey: key)
            // A short-lived CLI must publish preferences before returning to its caller.
            guard defaults.synchronize() else { throw CLIError("preferences_unavailable", "Preferences could not be persisted") }
            return result([key: value], changed: true)
        case "reset":
            guard arguments.count == 2 else { throw error("config reset requires one key") }
            let key = arguments[1]
            guard let field = fields[key] else { throw error("Unsupported setting: \(key)") }
            defaults.removeObject(forKey: key)
            guard defaults.synchronize() else { throw CLIError("preferences_unavailable", "Preferences could not be persisted") }
            return result([key: field.fallback], changed: true)
        default:
            throw error("Unknown config operation: \(operation)")
        }
    }

    private static func validate(_ value: Any, field: Field) throws -> Any {
        switch field.kind {
        case .boolean:
            // NSNumber bridging otherwise accepts 0/1 as Bool and true as Int.
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { throw error("Expected true or false") }
            return number.boolValue
        case .integer(let range):
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(range.lowerBound),
                  number.doubleValue <= Double(range.upperBound) else {
                throw error("Expected integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return number.intValue
        case .choice(let allowed):
            guard let string = value as? String, allowed.contains(string) else {
                throw error("Expected one of: \(allowed.joined(separator: ", "))")
            }
            return string
        case .languages:
            let allowed = Set(["zh-Hans", "zh-Hant", "en-US"])
            guard let list = value as? [String], !list.isEmpty,
                  Set(list).count == list.count, list.allSatisfy({ allowed.contains($0) }) else {
                throw error("Expected a nonempty JSON array of unique OCR languages: zh-Hans, zh-Hant, en-US")
            }
            return list
        }
    }

    private static func result(_ values: [String: Any], changed: Bool) -> [String: Any] {
        ["ok": true, "settings": values, "preferences_domain": PreferencesDomain.name,
         "restart_required": changed]
    }
    private static func error(_ message: String) -> HeadlessSettingsError {
        HeadlessSettingsError(message: message)
    }
}
