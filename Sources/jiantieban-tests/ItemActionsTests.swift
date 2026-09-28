import Core
import Foundation

/// "这条能做什么"的唯一出处。这里守住的是：图片永远不能加密/重命名；密钥不能再加密，也没有取消密钥（ADR-0001）；明文没有命名。
enum ItemActionsTests {
    static let all: [TestCase] = [
        TestCase("image: no secret actions", testImage),
        TestCase("plain text: mark + encrypt, no rename/plaintext", testPlain),
        TestCase("secret: rename + plaintext, no re-encrypt, no mark toggle", testSecret),
        TestCase("hints never mention ↩ and use 2-char labels", testHints),
    ]

    static let image = ClipItem(kind: .image, content: "", imagePath: "/tmp/a.png", thumbPath: "/tmp/a-thumb.png")
    static let plain = ClipItem(kind: .text, content: "hello")
    static let secret = ClipItem(kind: .text, content: "jt://secret/x", isSecret: true, secretToken: "jt://secret/x", secretName: "OpenAI")

    static func testImage() throws {
        let a = ItemActions.available(for: image)
        try expect(!a.contains(.markSecret) && !a.contains(.pasteAsSecret) && !a.contains(.rename) && !a.contains(.pastePlaintext), "image got secret actions: \(a)")
        try expect(a.contains(.paste) && a.contains(.expand) && a.contains(.openInEditor) && a.contains(.delete))
    }

    static func testPlain() throws {
        let a = ItemActions.available(for: plain)
        try expect(a.contains(.markSecret) && a.contains(.pasteAsSecret))
        try expect(!a.contains(.rename) && !a.contains(.pastePlaintext), "plain got secret-only actions: \(a)")
    }

    static func testSecret() throws {
        let a = ItemActions.available(for: secret)
        try expect(!a.contains(.openInEditor), "opening a secret would write its plaintext to a temp file")
        try expect(a.contains(.rename) && a.contains(.pastePlaintext))
        try expect(!a.contains(.markSecret) && !a.contains(.pasteAsSecret), "secret can be re-encrypted: \(a)")
    }

    static func testHints() throws {
        for item in [image, plain, secret] {
            for expanded in [false, true] {
                let hints = ItemActions.hints(for: item, expanded: expanded, copyOnly: false)
                try expect(!hints.contains { $0.key == "↩" }, "plain ↩ is common knowledge, should not be hinted")
                for h in hints { try expectEqual(h.label.count, 2, "label '\(h.label)' must be 2 chars") }
            }
        }
        try expect(ItemActions.hints(for: image, expanded: false, copyOnly: false).contains { $0.key == "⌘R" && $0.label == "预览" })
        try expect(ItemActions.hints(for: secret, expanded: true, copyOnly: false).contains { $0.key == "⌘R" && $0.label == "收起" })
    }
}
