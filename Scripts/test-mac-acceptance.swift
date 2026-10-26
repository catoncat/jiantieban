#!/usr/bin/env swift
// Safe macOS process acceptance. Run from any directory:
//   swift Scripts/test-mac-acceptance.swift [standalone-binary [bundle-binary]]
//
// Uses a temporary history directory and a UUID preferences suite. Never opens
// the GUI, grants permissions, signs anything, or reads/writes general pasteboard
// contents. Observes only its changeCount, foreground PID, and child-owned windows.
// watch is started with privacyMode=true: the implementation must leave its
// clipboard monitor stopped in this mode. No synthetic clipboard change is made.
// A valid-ID paste is attempted only after that exact binary's doctor reports
// accessibility_trusted=false. Never grant Accessibility while this test runs.
// External clipboard/focus changes invalidate the observation; nothing is restored.
// This does not prove capture filtering or successful paste into a target app.

import AppKit
import CoreGraphics
import Darwin
import Foundation

private struct AcceptanceFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct CommandResult {
    let status: Int32
    let reason: Process.TerminationReason
    let stdout: Data
    let stderr: Data
}

@MainActor
private final class Acceptance {
    let temporary: URL
    let suite = "rs.jiantieban.mac-acceptance." + UUID().uuidString
    let standalone: URL
    let bundled: URL
    let defaults: UserDefaults
    var environment: [String: String]
    var calls = 0
    var observations = 0
    var passed: [String] = []
    var skipped: [String] = []

    init(standalone: URL, bundled: URL) throws {
        let fm = FileManager.default
        for binary in [standalone, bundled] {
            guard fm.isExecutableFile(atPath: binary.path) else {
                throw AcceptanceFailure("Build both executable targets first; missing: \(binary.path)")
            }
        }
        self.standalone = standalone
        self.bundled = bundled
        temporary = fm.temporaryDirectory.appendingPathComponent("jtb-mac-acceptance-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard let preferences = UserDefaults(suiteName: suite) else {
            try? fm.removeItem(at: temporary)
            throw AcceptanceFailure("Cannot open the isolated preferences suite")
        }
        defaults = preferences
        environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("JIANTIEBAN_") }
        environment["JIANTIEBAN_HOME"] = temporary.appendingPathComponent("history").path
        environment["JIANTIEBAN_PREFERENCES_SUITE"] = suite
        environment["JT_BIN"] = temporary.appendingPathComponent("no-jt").path
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        if !defaults.synchronize() {
            FileHandle.standardError.write(Data("warning: isolated preferences cleanup could not be confirmed\n".utf8))
        }
        try? FileManager.default.removeItem(at: temporary)
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AcceptanceFailure(message) }
    }

    // Never examine window titles, owner names, or any other app's window data.
    func observe(_ process: Process, foreground: pid_t, clipboardCount: Int) throws {
        try require(NSPasteboard.general.changeCount == clipboardCount,
                    "Pasteboard changeCount changed; observation is inconclusive (no content was read or restored)")
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                    "Foreground application changed; observation is inconclusive")
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            throw AcceptanceFailure("Window inventory unavailable; cannot verify a headless process")
        }
        let childHasWindow = windows.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier
        }
        try require(!childHasWindow, "The CLI child created a window")
        observations += 1
    }

    // Every started child has a bounded lifetime, including error/cleanup paths.
    // Files avoid pipe deadlocks when testing long stdin or large JSON responses.
    func command(_ binary: URL, _ arguments: [String], input: Data = Data(),
                 home: URL? = nil, watchFor: TimeInterval? = nil) throws -> CommandResult {
        guard let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw AcceptanceFailure("No foreground application is observable; interactive-session checks are unavailable")
        }
        let clipboardCount = NSPasteboard.general.changeCount
        calls += 1
        let folder = temporary.appendingPathComponent("process-\(calls)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let inputURL = folder.appendingPathComponent("stdin")
        let outputURL = folder.appendingPathComponent("stdout")
        let errorURL = folder.appendingPathComponent("stderr")
        try input.write(to: inputURL)
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var childEnvironment = environment
        if let home { childEnvironment["JIANTIEBAN_HOME"] = home.path }
        process.environment = childEnvironment
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()

        func stop() -> Bool {
            guard process.isRunning else { return true }
            process.interrupt()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                return false
            }
            return true
        }

        do {
            let deadline = ProcessInfo.processInfo.systemUptime + (watchFor ?? 12)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                try observe(process, foreground: foreground, clipboardCount: clipboardCount)
                Thread.sleep(forTimeInterval: 0.02)
            }
            if watchFor != nil {
                try require(process.isRunning, "watch exited before the observation interval completed")
                try require(stop(), "watch failed to stop on SIGINT within two seconds")
            } else if process.isRunning {
                _ = stop()
                throw AcceptanceFailure("CLI subprocess exceeded its 12-second timeout: \(arguments.first ?? "")")
            }
            try observe(process, foreground: foreground, clipboardCount: clipboardCount)
        } catch {
            _ = stop()
            throw error
        }
        try require(!process.isRunning, "CLI subprocess remains alive after termination")
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        return CommandResult(status: process.terminationStatus, reason: process.terminationReason,
                             stdout: try Data(contentsOf: outputURL), stderr: try Data(contentsOf: errorURL))
    }

    func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AcceptanceFailure("Expected a JSON object")
        }
        return object
    }

    func success(_ binary: URL, _ arguments: [String], input: Data = Data(), home: URL? = nil) throws -> [String: Any] {
        let run = try command(binary, arguments, input: input, home: home)
        try require(run.reason == .exit && run.status == 0, "CLI command failed: \(arguments.first ?? "")")
        try require(run.stderr.isEmpty, "Successful CLI command wrote stderr")
        let envelope = try object(run.stdout)
        try require(envelope["ok"] as? Bool == true && envelope["schema_version"] as? Int == 1,
                    "Invalid success envelope")
        try require(envelope["command"] as? String == arguments.first, "Success command field mismatch")
        guard let result = envelope["result"] as? [String: Any] else {
            throw AcceptanceFailure("Expected an object result")
        }
        return result
    }

    func failure(_ binary: URL, _ arguments: [String], status: Int32, code: String) throws -> [String: Any] {
        let run = try command(binary, arguments)
        try require(run.reason == .exit && run.status == status, "Unexpected failure exit code: \(arguments.first ?? "")")
        try require(run.stdout.isEmpty, "Failed CLI command wrote stdout")
        let envelope = try object(run.stderr)
        try require(envelope["ok"] as? Bool == false && envelope["code"] as? String == code,
                    "Unexpected error contract: \(arguments.first ?? "")")
        return envelope
    }

    func run() throws {
        let fm = FileManager.default
        let history = URL(fileURLWithPath: environment["JIANTIEBAN_HOME"]!)
        for binary in [standalone, bundled] {
            let diagnostic = try success(binary, ["doctor"])
            try require(diagnostic["preferences_domain"] as? String == suite, "doctor selected the wrong preferences suite")
            try require(diagnostic["database_exists"] as? Bool == false, "doctor unexpectedly found a database")
            try require(diagnostic["permission_prompted"] as? Bool == false, "doctor reported a permission prompt")
            try require(diagnostic["capture_status"] as? String == "unknown", "doctor claimed capture health")
            try require(diagnostic["interactive_session_status"] as? String == "not_checked", "doctor claimed interaction acceptance")
            try require(!fm.fileExists(atPath: history.path), "doctor created history storage")
        }
        passed.append("standalone and bundle doctor left absent storage absent")

        _ = try success(standalone, ["config", "set", "hardLimit", "100"])
        let configured = try success(bundled, ["config", "get", "hardLimit"])
        try require((configured["settings"] as? [String: Any])?["hardLimit"] as? Int == 100,
                    "Bundle did not read standalone preferences")
        _ = try success(bundled, ["config", "reset", "hardLimit"])
        let reset = try success(standalone, ["config", "get", "hardLimit"])
        try require((reset["settings"] as? [String: Any])?["hardLimit"] as? Int == 600,
                    "Standalone did not observe bundle preferences reset")
        try require(!fm.fileExists(atPath: history.path), "config created history storage")
        passed.append("standalone and bundle shared isolated settings across process restarts")

        // Test-owned fixture setup, deliberately outside the public config allowlist.
        defaults.set(true, forKey: "privacyMode")
        defaults.set(true, forKey: "autoExcludeSecrets")
        try require(defaults.synchronize(), "Could not persist isolated privacy settings")
        for (index, binary) in [standalone, bundled].enumerated() {
            let watchHome = temporary.appendingPathComponent("watch-\(index)")
            let watch = try command(binary, ["watch"], home: watchHome, watchFor: 2)
            try require(watch.reason == .uncaughtSignal && watch.status == SIGINT,
                        "watch did not terminate normally on SIGINT")
            try require(watch.stderr.isEmpty, "watch wrote unexpected stderr")
            try require(fm.fileExists(atPath: watchHome.appendingPathComponent("jiantieban.db").path),
                        "watch never initialized its isolated history")
            let count = try success(binary, ["stats", "--json"], home: watchHome)
            try require(count["items"] as? Int == 0, "Privacy-mode watch stored clipboard history")
        }
        passed.append("privacy-mode watch stayed headless, preserved focus/changeCount, stopped on SIGINT, and left empty history")

        let sample = String(repeating: "无害验收🙂\n", count: 3000)
        let added = try success(standalone, ["add-text", "--stdin", "--json"], input: Data(sample.utf8))
        try require(added["truncated"] as? Bool == true, "Long input did not report truncation")
        guard let item = added["item"] as? [String: Any], let identifier = item["id"] as? String else {
            throw AcceptanceFailure("Mutation did not return a string ID")
        }
        try require(Set(item.keys) == ["id", "kind", "is_favorite", "is_secret", "was_pasted"],
                    "Mutation returned more than minimal metadata")
        let raw = try command(bundled, ["get", identifier, "--raw"])
        try require(raw.status == 0 && raw.stderr.isEmpty && raw.stdout == Data(sample.prefix(12000).utf8),
                    "Raw output differs from the saved UTF-8 prefix")
        let record = try success(bundled, ["get", identifier])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for key in ["created_at", "last_copied_at"] {
            guard let date = record[key] as? String else { throw AcceptanceFailure("Missing timestamp") }
            try require(date.hasSuffix("Z") && formatter.date(from: date) != nil, "Timestamp is not UTC ISO 8601")
        }
        passed.append("long Unicode stdin returned only the saved prefix, minimal mutation metadata, and UTC timestamps")

        for name in ["secrets", "annotate", "resolve", "unmark-secret"] {
            let moved = try command(standalone, [name])
            try require(moved.reason == .exit && moved.status == 2 && moved.stdout.isEmpty,
                        "Legacy command must fail with exit code 2")
            try require(String(decoding: moved.stderr, as: UTF8.self).contains("jt"),
                        "Legacy command did not explain the jt destination")
            _ = try failure(standalone, [name, "--json"], status: 2, code: "invalid_arguments")
        }
        _ = try failure(standalone, ["clear", "--json"], status: 2, code: "invalid_arguments")
        _ = try failure(standalone, ["copy", identifier, "--format", "original"], status: 1, code: "format_unavailable")
        passed.append("legacy commands and destructive-operation/format errors retained their contracts")

        // A deleted test-owned PNG verifies copy's no-write error path. Never copy
        // valid data: that would overwrite the user's general pasteboard.
        let fixture = temporary.appendingPathComponent("fixture.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        try png.write(to: fixture)
        let imageAdded = try success(standalone, ["add-image", fixture.path, "--json"])
        guard let imageItem = imageAdded["item"] as? [String: Any], let imageID = imageItem["id"] as? String else {
            throw AcceptanceFailure("Image mutation returned no ID")
        }
        let image = try success(standalone, ["get", imageID])
        guard let imagePath = image["image_path"] as? String,
              URL(fileURLWithPath: imagePath).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                == history.appendingPathComponent("images").standardizedFileURL.resolvingSymlinksInPath().path else {
            throw AcceptanceFailure("Image path was outside test-owned storage")
        }
        try fm.removeItem(atPath: imagePath)
        let missingImage = try failure(standalone, ["copy", imageID], status: 1, code: "content_unavailable")
        try require(missingImage["clipboard_changed"] as? Bool == false, "Missing image reported a clipboard mutation")
        passed.append("missing test image failed copy without changing general pasteboard")

        for (name, binary) in [("standalone", standalone), ("bundle", bundled)] {
            let diagnostic = try success(binary, ["doctor"])
            guard let trusted = diagnostic["accessibility_trusted"] as? Bool else {
                throw AcceptanceFailure("doctor did not provide Accessibility status")
            }
            if trusted {
                skipped.append("\(name) valid-ID paste: Accessibility already trusted; skipped to avoid sending an event")
                continue
            }
            let denied = try failure(binary, ["paste", identifier], status: 1, code: "accessibility_required")
            try require(denied["clipboard_changed"] as? Bool == false, "Denied paste reported a clipboard mutation")
            passed.append("\(name) valid-ID paste failed with accessibility_required and unchanged pasteboard")
        }
        let report: [String: Any] = [
            "ok": true, "processes": calls, "headless_observation_samples": observations,
            "passed": passed, "skipped": skipped,
            "limits": ["No general pasteboard content was read or written by this harness.",
                       "Window/focus observations are sampled, not proof against sub-sample transient UI.",
                       "Privacy watch startup was tested without generating a clipboard change.",
                       "Successful target-app paste, live capture filtering, GUI and permission changes remain untested."]
        ]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}

do {
    try MainActor.assumeIsolated {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count <= 2 else {
            throw AcceptanceFailure("Usage: swift Scripts/test-mac-acceptance.swift [standalone-binary [bundle-binary]]")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let standalone = arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? repository.appendingPathComponent(".build/release/jiantieban")
        let bundled = arguments.count == 2 ? URL(fileURLWithPath: arguments[1]).standardizedFileURL
            : repository.appendingPathComponent("build/jiantieban.app/Contents/MacOS/jiantieban")
        let acceptance = try Acceptance(standalone: standalone, bundled: bundled)
        defer { acceptance.cleanup() }
        try acceptance.run()
    }
} catch {
    FileHandle.standardError.write(Data("macOS acceptance failed: \(error)\n".utf8))
    exit(1)
}
