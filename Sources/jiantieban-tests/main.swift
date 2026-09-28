import Foundation

let suites: [(String, [TestCase])] = [
    ("Store", StoreTests.all),
    ("Ingest", IngestTests.all),
    ("Secret", SecretTests.all),
    ("PastebackCoordinator", PastebackCoordinatorTests.all),
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
