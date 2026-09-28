import Core
import Foundation

/// 密钥记录功能测试：标记、撤销标记、解析、命名。
enum SecretTests {
    static var all: [TestCase] {
        [
            TestCase("detect known key prefixes", testDetectPrefixes),
            TestCase("non-secret not detected", testNonSecret),
            TestCase("prefix rules need a whole token: sentences starting with sk-/AKIA are not keys", testPrefixNeedsWholeToken),
            TestCase("masked preview keeps head/tail", testMaskedPreview),
            TestCase("mark as secret stores only the jt reference", testMarkAsSecret),
            TestCase("resolve secret token returns plaintext", testResolve),
            TestCase("undo mark restores plaintext", testUndoMark),
            TestCase("undo mark restores the real value, not the reference", testUndoMarkRestoresRealValue),
            TestCase("undo mark: any failed step leaves the secret intact and resolvable", testUndoMarkFailureKeepsSecret),
            TestCase("unnamed secret shows its mask, never the engine default name", testDisplayTitle),
            TestCase("undo mark when the plaintext was copied again merges into one plain row", testUndoMarkMergesExistingPlaintext),
            TestCase("value larger than the pipe buffer resolves instead of hanging", testLargeValueDoesNotDeadlock),
        ]
    }

    @MainActor
    static func testDetectPrefixes() throws {
        try expectEqual(SecretDetector.detect("sk-" + String(repeating: "x", count: 40)), .openaiKey)
        // 回归：sk- 规则排在前面，Anthropic 的 sk-ant- 一直被认成 OpenAI
        try expectEqual(SecretDetector.detect("sk-ant-api03-" + String(repeating: "x", count: 40)), .anthropicKey)
        try expectEqual(SecretDetector.detect("ghp_abcdefghijklmnop"), .githubPat)
        try expectEqual(SecretDetector.detect("AKIAIOSFODNN7EXAMPLE"), .awsAccessKey)
        try expectEqual(SecretDetector.detect("AIzaSy" + String(repeating: "a", count: 30)), .gcpApiKey)
        try expectEqual(SecretDetector.detect("sk_live_abcdefghijklmnop"), .stripeKey)
        try expectEqual(SecretDetector.detect("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc"), .jwt)
        try expectEqual(SecretDetector.detect("Bearer eyJabc123def456ghi789jkl"), .bearerToken)
    }

    @MainActor
    static func testNonSecret() throws {
        try expect(SecretDetector.detect("hello world") == nil)
        try expect(SecretDetector.detect("just some normal text 12345") == nil)
    }

    static func testMaskedPreview() throws {
        try expectEqual(SecretMask.fixed("sk-abcdefghijklmnop"), "sk••••••mnop", "固定 前2+6•+后4，不还原长度")
        try expectEqual(SecretMask.fixed("short"), "•••••")
    }

    /// 回归：前缀规则只看开头，"sk-learn 是 Python 库…" 这种普通句子被认成 OpenAI Key（命名推荐会预填错）。
    static func testPrefixNeedsWholeToken() throws {
        for text in ["sk-learn is a Python library for machine learning", "AKIA is the prefix of AWS access keys",
                     "ghp_ tokens are GitHub personal access tokens", "sk-short"] {
            try expect(SecretDetector.detect(text) == nil, "\(text) must not be detected")
        }
    }

    @MainActor
    static func testMarkAsSecret() throws {
        let (store, secrets) = try makeEngine()
        let (item, _) = try store.upsertText("sk-" + String(repeating: "a", count: 40))
        let source = BrowserSource(bundleID: "com.google.Chrome", title: "私密后台", url: "https://example.com/private")
        try store.setBrowserSource(source, forItemID: item.id, copiedAt: item.lastCopiedAt)
        let marked = try secrets.markAsSecret(id: item.id, name: "openai-prod")

        try expect(marked.isSecret)
        try expect(marked.secretToken?.hasPrefix("jt://secret/") == true)
        try expectEqual(marked.content, marked.secretToken, "the local DB keeps only the reference, never the value")
        try expectEqual(marked.secretName, "openai-prod")
        try expect(marked.maskedPreview?.hasPrefix("sk") == true)
        try expectEqual(marked.secretType, SecretType.openaiKey.rawValue)
        try expect(marked.browserSource == nil, "标记密钥时不保留网页来源")
    }

    @MainActor
    static func testResolve() throws {
        let (store, secrets) = try makeEngine()
        let (item, _) = try store.upsertText("ghp_abcdefghijklmnopqrstuvwxyz")
        let marked = try secrets.markAsSecret(id: item.id)
        let token = try unwrap(marked.secretToken)
        try expectEqual(try secrets.resolve(token: token), "ghp_abcdefghijklmnopqrstuvwxyz")
        try expect((try? secrets.resolve(token: "jt://secret/nope")) == nil, "unknown reference must fail")
    }

    @MainActor
    static func testUndoMark() throws {
        let (store, secrets) = try makeEngine()
        let (item, _) = try store.upsertText("plain-secret-value")
        _ = try secrets.markAsSecret(id: item.id, name: "temp")
        let restored = try secrets.undoMark(id: item.id).item

        try expect(!restored.isSecret)
        try expectEqual(restored.content, "plain-secret-value")
        try expect(restored.secretToken == nil)
        try expect(restored.secretName == nil)
        try expect(restored.maskedPreview == nil)
    }

    /// 回归：默认名 `jiantieban/<id>` 的生成和识别曾分在 SecretManager 与列表两处。
    @MainActor
    static func testDisplayTitle() throws {
        let (store, secrets) = try makeEngine()
        let (item, _) = try store.upsertText("sk-" + String(repeating: "b", count: 40))
        let marked = try secrets.markAsSecret(id: item.id)
        try expect(marked.userFacingSecretName == nil, "engine default name must not count as a user name")
        try expectEqual(marked.displayTitle, "sk••••••bbbb")
        let named = try secrets.setName(id: item.id, name: "OpenAI")
        try expectEqual(named.displayTitle, "OpenAI")
    }

    /// 回归：标记后又复制了一次同样的值，取消密钥（现为撤销标记）撞文本去重唯一索引而失败——
    /// 而 jt 里的真值已经先删掉了，这条密钥从此解析不出来。
    @MainActor
    static func testUndoMarkMergesExistingPlaintext() throws {
        let (store, secrets) = try makeEngine()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(60)
        let (item, _) = try store.upsertText("dup-secret-value-123", at: t1)
        let token = try unwrap(try secrets.markAsSecret(id: item.id).secretToken)
        let (copy, inserted) = try store.upsertText("dup-secret-value-123", at: t2)
        try expect(inserted, "re-copying the value creates a plain row next to the secret")
        try store.toggleFavorite(id: copy.id)
        try store.markPasted(id: copy.id)
        let source = BrowserSource(bundleID: "com.google.Chrome", title: "再次复制", url: "https://example.com/latest")
        try store.setBrowserSource(source, forItemID: copy.id, copiedAt: t2)

        _ = try secrets.undoMark(id: item.id)

        try expectEqual(try store.count(), 1, "merged into one row")
        let merged = try unwrap(try store.item(id: item.id))
        try expect(!merged.isSecret && merged.secretToken == nil)
        try expectEqual(merged.content, "dup-secret-value-123")
        try expect(merged.isFavorite, "favorite survives the merge")
        try expect(merged.wasPasted, "pasted status survives the merge")
        try expectEqual(merged.browserSource, source, "newest source survives the merge")
        try expectEqual(merged.lastCopiedAt, t2, "keeps the newer copy time")
        try expect((try? secrets.resolve(token: token)) == nil, "vault entry is removed after the merge")
    }

    /// 回归：先等 jt 退出再读输出。输出超过管道缓冲（64KB）时 jt 写不出去、永远不退出，App 卡死。
    /// 单条上限可调到 5 万字（中文约 150KB），对这样的密钥按 ⇧⌘↩ 贴明文就会触发。
    @MainActor
    static func testLargeValueDoesNotDeadlock() throws {
        let (store, secrets) = try makeEngine()
        store.config.maxSaveLength = 50_000
        let big = String(repeating: "密钥内容", count: 12_500)
        let (item, _) = try store.upsertText(big)
        let marked = try secrets.markAsSecret(id: item.id)
        try expectEqual(try secrets.resolveValue(for: marked), big)
    }

    // MARK: - Helpers


    /// 回归：取消标记（现为撤销标记）曾把 `jt://secret/…` 引用串写回当明文，且先 rm 再无法取回真值（真值丢失）。
    @MainActor
    static func testUndoMarkRestoresRealValue() throws {
        let (store, secrets) = try makeEngine()
        let (item, _) = try store.upsertText("real-plain-value-123")
        let marked = try secrets.markAsSecret(id: item.id, name: "t")
        let token = try unwrap(marked.secretToken)
        try expect(token.hasPrefix("jt://secret/"))
        try expectEqual(try secrets.resolve(token: token), "real-plain-value-123")

        let restored = try secrets.undoMark(id: item.id).item
        try expect(!restored.isSecret)
        try expectEqual(restored.content, "real-plain-value-123", "撤销标记必须写回真值，而不是引用串")
        try expect((try? secrets.resolve(token: token)) == nil, "撤销后 vault 里不应再有这条")

        // 再标记一次存进 jt 的必须还是真值（不是引用串）
        let again = try secrets.markAsSecret(id: item.id, name: "t2")
        try expectEqual(try secrets.resolve(token: try unwrap(again.secretToken)), "real-plain-value-123")
    }

    /// 取不回真值就什么都不改；写回后 jt rm 失败只记日志，vault 多留一份不算失败。
    @MainActor
    static func testUndoMarkFailureKeepsSecret() throws {
        let store = try ClipStore()
        let (secrets, jt) = try FakeJT.make(store: store)
        let (item, _) = try store.upsertText("keep-me-value-123")
        let token = try unwrap(try secrets.markAsSecret(id: item.id).secretToken)

        jt.failing("resolve")
        try expect((try? secrets.undoMark(id: item.id)) == nil, "resolve failure must surface")
        try expect(try store.item(id: item.id)?.isSecret == true, "still a secret row")
        jt.failing("resolve", nil)
        try expectEqual(try secrets.resolve(token: token), "keep-me-value-123", "value still in the vault")

        jt.failing("rm")
        let restored = try secrets.undoMark(id: item.id).item
        try expectEqual(restored.content, "keep-me-value-123", "rm failure does not undo the undo")
        try expectEqual(jt.value(of: token), "keep-me-value-123", "the extra vault copy stays")
    }

    @MainActor
    private static func makeEngine() throws -> (ClipStore, SecretManager) {
        let store = try ClipStore()
        return (store, try FakeJT.makeSecretManager(store: store))
    }
}
