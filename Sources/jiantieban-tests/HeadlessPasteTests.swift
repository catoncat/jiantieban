import Core
import Foundation

enum HeadlessPasteTests {
    static let all: [TestCase] = [
        TestCase("headless paste parses generic record selectors and format overrides", testParse),
        TestCase("headless paste rejects missing, conflicting, malformed and surplus arguments", testInvalidArguments),
        TestCase("headless paste defaults obey format policy without inventing preserved text", testTextFormats),
        TestCase("headless paste image format overrides do not silently OCR", testImageFormats),
        TestCase("headless paste never resolves reference records to secret plaintext", testReferences),
        TestCase("headless paste latest follows copy recency, not favorites or id", testLatest),
        TestCase("headless paste latest timestamp tie breaks deterministically", testLatestTie),
        TestCase("headless paste empty and deleted history report item_not_found", testMissing),
    ]

    static func expectError(_ code: String, exitCode: Int32 = 1, _ body: () throws -> Void) throws {
        do {
            try body()
            throw TestFailure("expected \(code)")
        } catch let error as HeadlessPasteError {
            try expectEqual(error.code, code)
            try expectEqual(error.exitCode, exitCode)
        }
    }

    static func testParse() throws {
        try expectEqual(try HeadlessPasteRequest.parse(["42"]), HeadlessPasteRequest(selector: .id(42)))
        try expectEqual(try HeadlessPasteRequest.parse(["--latest"]), HeadlessPasteRequest(selector: .latest))
        for format in [HeadlessPasteFormat.default, .plain, .original] {
            try expectEqual(try HeadlessPasteRequest.parse(["--format", format.rawValue, "7"]), HeadlessPasteRequest(selector: .id(7), format: format))
            try expectEqual(try HeadlessPasteRequest.parse(["--latest", "--format", format.rawValue]), HeadlessPasteRequest(selector: .latest, format: format))
        }
        try expectEqual(HeadlessPasteFormat.default.usesPlainText(defaultPlainText: true), true)
        try expectEqual(HeadlessPasteFormat.default.usesPlainText(defaultPlainText: false), false)
        try expectEqual(HeadlessPasteFormat.plain.usesPlainText(defaultPlainText: false), true)
        try expectEqual(HeadlessPasteFormat.original.usesPlainText(defaultPlainText: true), false)
    }

    static func testInvalidArguments() throws {
        let invalid: [[String]] = [
            [], ["--format", "plain"], ["0"], ["-1"], ["+1"], ["1.0"], [" 1"], [""],
            ["9223372036854775808"], ["1", "2"], ["1", "--latest"], ["--latest", "1"],
            ["--latest", "--latest"], ["--latest", "--format"], ["--latest", "--format", "rich"],
            ["--latest", "--format", "plain", "--format", "plain"], ["--latest", "--unknown"],
            ["--latest", "trailing"], ["latest"], ["--format=plain", "1"],
        ]
        for arguments in invalid {
            try expectError("invalid_arguments", exitCode: 2) { _ = try HeadlessPasteRequest.parse(arguments) }
        }
    }

    static func testTextFormats() throws {
        let item = ClipItem(id: 42, kind: .text, content: "hello\n世界")
        for preference in [false, true] {
            for format in [HeadlessPasteFormat.default, .plain] {
                let request = HeadlessPasteRequest(selector: .id(item.id), format: format)
                try expectEqual(try request.content(for: item, defaultPlainText: preference, imageAsFile: false), .text(item.content))
            }
            let request = HeadlessPasteRequest(selector: .id(item.id), format: .original)
            try expectError("format_unavailable") { _ = try request.content(for: item, defaultPlainText: preference, imageAsFile: false) }
        }
    }

    static func testImageFormats() throws {
        let image = ClipItem(id: 3, kind: .image, content: "[图片]", imagePath: "/tmp/example.png", ocrText: "not the original")
        let defaultRequest = HeadlessPasteRequest(selector: .id(3))
        for asFile in [false, true] {
            try expectEqual(try defaultRequest.content(for: image, defaultPlainText: true, imageAsFile: asFile), .image(path: "/tmp/example.png", asFile: asFile))
        }
        let original = HeadlessPasteRequest(selector: .id(3), format: .original)
        try expectEqual(try original.content(for: image, defaultPlainText: true, imageAsFile: true), .image(path: "/tmp/example.png", asFile: false))
        let plain = HeadlessPasteRequest(selector: .id(3), format: .plain)
        try expectError("format_unavailable") { _ = try plain.content(for: image, defaultPlainText: true, imageAsFile: false) }
        var missing = image
        missing.imagePath = nil
        try expectError("content_unavailable") { _ = try defaultRequest.content(for: missing, defaultPlainText: false, imageAsFile: false) }
    }

    static func testReferences() throws {
        let token = "jt://secret/example"
        let item = ClipItem(id: 5, kind: .text, content: token, isSecret: true, secretToken: token)
        for format in [HeadlessPasteFormat.default, .plain, .original] {
            let request = HeadlessPasteRequest(selector: .id(5), format: format)
            try expectEqual(try request.content(for: item, defaultPlainText: true, imageAsFile: false), .secretReference(token))
            var missing = item
            missing.secretMissing = true
            try expectError("content_unavailable") { _ = try request.content(for: missing, defaultPlainText: true, imageAsFile: false) }
            missing = item
            missing.secretToken = nil
            try expectError("content_unavailable") { _ = try request.content(for: missing, defaultPlainText: true, imageAsFile: false) }
        }
    }

    @MainActor
    static func testLatest() throws {
        let store = try ClipStore()
        let old = try store.upsertText("old favorite", at: Date(timeIntervalSince1970: 10)).item
        try store.setFavorite(true, id: old.id)
        let recent = try store.upsertText("recent", at: Date(timeIntervalSince1970: 20)).item
        let request = HeadlessPasteRequest(selector: .latest)
        try expectEqual(try request.select(from: store).id, recent.id)
        _ = try store.upsertText("old favorite", at: Date(timeIntervalSince1970: 30))
        try expectEqual(try request.select(from: store).id, old.id)
        try expectEqual(try HeadlessPasteRequest(selector: .id(recent.id)).select(from: store).id, recent.id)
    }

    @MainActor
    static func testLatestTie() throws {
        let store = try ClipStore()
        let time = Date(timeIntervalSince1970: 100)
        _ = try store.upsertText("a", at: time)
        let b = try store.upsertText("b", at: time).item
        try expectEqual(try store.latestItem()?.id, b.id)
    }

    @MainActor
    static func testMissing() throws {
        let store = try ClipStore()
        let latest = HeadlessPasteRequest(selector: .latest)
        try expectError("item_not_found") { _ = try latest.select(from: store) }
        let item = try store.upsertText("deleted").item
        _ = try store.delete(id: item.id)
        try expectError("item_not_found") { _ = try HeadlessPasteRequest(selector: .id(item.id)).select(from: store) }
        try expectError("item_not_found") { _ = try latest.select(from: store) }
    }
}
