import AppKit
import Core
import Foundation
import PastebackPlatform

// Test-only subprocess: exercise pasteboard persistence after its writer exits.
// A unique named pasteboard is supplied by the parent; never use .general here.
if CommandLine.arguments.count == 4,
   CommandLine.arguments[1] == "--test-write-image" {
    let status: Int32 = MainActor.assumeIsolated {
        let board = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[2]))
        let writer = SystemPastebackClipboard(pasteboard: board)
        return writer.write(.image(path: CommandLine.arguments[3], asFile: false)) ? 0 : 1
    }
    exit(status)
}

let suites: [(String, [TestCase])] = [
    ("Store", StoreTests.all),
    ("Ingest", IngestTests.all),
    ("Secret", SecretTests.all),
    ("PastebackCoordinator", PastebackCoordinatorTests.all),
    ("HeadlessPaste", HeadlessPasteTests.all),
    ("HeadlessPasteExecutor", HeadlessPasteExecutorTests.all),
    ("SystemPastebackClipboard", SystemPastebackClipboardTests.all),
    ("ItemActions", ItemActionsTests.all),
    ("Keymap", KeymapTests.all),
    ("PanelSession", PanelSessionTests.all),
    ("SecretView", SecretViewTests.all),
    ("ReferenceClip", ReferenceClipTests.all),
    ("SecretNaming", SecretNamingTests.all),
    ("VaultNotice", VaultNoticeTests.all),
    ("PanelLayout", PanelLayoutTests.all),
]

var passed = 0
var failed = 0

MainActor.assumeIsolated {
for (suite, tests) in suites {
    print("== \(suite) ==")
    for test in tests {
        do {
            try test.body()
            passed += 1
            print("  ✓ \(test.name)")
        } catch {
            failed += 1
            print("  ✗ \(test.name): \(error)")
        }
    }
}

}

print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }

