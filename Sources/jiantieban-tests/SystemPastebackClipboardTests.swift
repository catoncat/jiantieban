import AppKit
import Core
import Foundation
import PastebackPlatform

@MainActor
enum SystemPastebackClipboardTests {
    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("jiantieban-tests-\(UUID().uuidString)"))
    }

    private static func makeImageFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jiantieban-pasteback-\(UUID().uuidString).tiff")
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        guard let data = image.tiffRepresentation else {
            throw TestFailure("failed to create test image")
        }
        try data.write(to: url)
        return url
    }

    static let all: [TestCase] = [
        TestCase("文本写入同时包含自家 marker") {
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            let writer = SystemPastebackClipboard(pasteboard: pasteboard)

            try expect(writer.write(.text("hello")))
            try expectEqual(pasteboard.string(forType: .string), "hello")
            try expectEqual(pasteboard.string(forType: PasteboardMarker.selfType), "1")
        },
        TestCase("无效图片不会覆盖原剪贴板") {
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            pasteboard.setString("original", forType: .string)
            let writer = SystemPastebackClipboard(pasteboard: pasteboard)

            try expect(!writer.write(.image(path: "/missing/image.png", asFile: false)))
            try expectEqual(pasteboard.string(forType: .string), "original")
        },
        TestCase("无效文件引用不会覆盖原剪贴板") {
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            pasteboard.setString("original", forType: .string)
            let writer = SystemPastebackClipboard(pasteboard: pasteboard)

            try expect(!writer.write(.image(path: "/missing/image.png", asFile: true)))
            try expectEqual(pasteboard.string(forType: .string), "original")
        },
        TestCase("图片对象和文件引用使用对应剪贴板表示") {
            let imageURL = try makeImageFile()
            defer { try? FileManager.default.removeItem(at: imageURL) }
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            let writer = SystemPastebackClipboard(pasteboard: pasteboard)

            try expect(writer.write(.image(path: imageURL.path, asFile: false)))
            try expect(pasteboard.data(forType: .tiff) != nil, "expected TIFF image data")

            try expect(writer.write(.image(path: imageURL.path, asFile: true)))
            let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            try expectEqual(urls?.first?.path, imageURL.path)
            try expectEqual(pasteboard.string(forType: PasteboardMarker.selfType), "1")
        },
        TestCase("preparation race preserves newer external clipboard") {
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            pasteboard.setString("original", forType: .string)
            let writer = SystemPastebackClipboard(pasteboard: pasteboard)
            #if DEBUG
            writer.testingBeforeClear = {
                pasteboard.clearContents()
                pasteboard.setString("newer", forType: .string)
            }
            try expect(!writer.write(.text("requested")))
            try expectEqual(pasteboard.string(forType: .string), "newer")
            try expectEqual(pasteboard.string(forType: PasteboardMarker.selfType), nil)
            #endif
        },
        TestCase("copy after write receives no self marker or stale rollback") {
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            pasteboard.setString("original", forType: .string)
            let writer = SystemPastebackClipboard(pasteboard: pasteboard)
            #if DEBUG
            writer.testingAfterContentWrite = {
                pasteboard.clearContents()
                pasteboard.setString("newer", forType: .string)
            }
            try expect(!writer.write(.text("requested")))
            try expectEqual(pasteboard.string(forType: .string), "newer")
            try expectEqual(pasteboard.string(forType: PasteboardMarker.selfType), nil)
            #endif
        },
        TestCase("image data survives the writing process exiting") {
            let imageURL = try makeImageFile()
            defer { try? FileManager.default.removeItem(at: imageURL) }
            let pasteboard = makePasteboard()
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--test-write-image", pasteboard.name.rawValue, imageURL.path]
            try child.run()
            child.waitUntilExit()
            try expectEqual(child.terminationStatus, 0)
            // Remove the source too: successful reading must not use a file-backed
            // promise or provider that disappeared with the short-lived process.
            try FileManager.default.removeItem(at: imageURL)
            guard let tiff = pasteboard.data(forType: .tiff) else {
                throw TestFailure("image bytes disappeared after writer exit")
            }
            try expect(NSImage(data: tiff) != nil)
            try expectEqual(pasteboard.string(forType: PasteboardMarker.selfType), "1")
        },
    ]
}

