import ApplicationServices
import Foundation

/// Non-mutating diagnostics: never opens the database, reads clipboard contents,
/// resolves secrets, starts an app, or requests macOS permission.
@MainActor
enum HeadlessDiagnostics {
    static func snapshot() -> [String: Any] {
        let directory = dataDir()
        let database = directory.appendingPathComponent("jiantieban.db")
        return [
            "ok": true,
            "platform": "macOS",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "preferences_domain": PreferencesDomain.name,
            "data_directory": directory.path,
            "database_exists": FileManager.default.fileExists(atPath: database.path),
            "accessibility_trusted": AXIsProcessTrusted(),
            "capture_status": "unknown",
            "interactive_session_status": "not_checked",
            "settings_reload": "restart_required",
            "permission_prompted": false,
        ]
    }
}
