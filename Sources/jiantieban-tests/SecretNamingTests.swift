import Core
import Foundation

/// 命名推荐 `<命名空间>/<KEY>`（ADR-0001 / 05）：命名空间取 jt 里最近改过的那条，KEY 按识别出的类型给。
@MainActor
enum SecretNamingTests {
    static let all: [TestCase] = [
        TestCase("KEY 按类型给：OpenAI / Anthropic / GitHub / 云厂商 / 连接串按协议 / env 赋值用变量名；看不出是哪家的不给", testKeysByType),
        TestCase("拼推荐：有命名空间 → ns/KEY，认不出 → ns/，没有命名空间 → 只有 KEY，两样都没有 → nil", testComposition),
        TestCase("预填的推荐：带 KEY 整体选中，只有 ns/ 时光标在末尾", testSelection),
        TestCase("最近的命名空间：updated_at 最新、起过名的那条；默认名、没有命名空间、没有时间的不算；同一时刻按名称", testRecentNamespace),
        TestCase("标记后命名：预填 jt 里最近的命名空间 + KEY；认不出只填 ns/；jt 为空或读不到不带命名空间", testMarkSuggestsNamespace),
        TestCase("Esc 保留默认名（密钥视图显示未命名密钥）；⌘⇧↩ 不弹命名", testNoNameKeepsDefault),
        TestCase("vault 没变时推荐不再读 jt", testNamespaceUsesListingCache),
        TestCase("密钥视图里给默认名记录改名：命名空间取已读到的列表，类型取本地引用记录，不多调 jt", testSecretViewRenameSuggestion),
    ]

    private static let openAIKey = "sk-proj-" + String(repeating: "a", count: 40)

    static func testKeysByType() throws {
        let cases: [(String, String?)] = [
            (openAIKey, "OPENAI_API_KEY"),
            ("sk-ant-api03-" + String(repeating: "b", count: 40), "ANTHROPIC_API_KEY"),
            ("ghp_" + String(repeating: "c", count: 36), "GITHUB_TOKEN"),
            ("AKIA" + String(repeating: "D", count: 16), "AWS_ACCESS_KEY_ID"),
            ("AIza" + String(repeating: "e", count: 35), "GOOGLE_API_KEY"),
            ("xoxb-" + String(repeating: "1", count: 20), "SLACK_TOKEN"),
            ("sk_live_" + String(repeating: "f", count: 24), "STRIPE_SECRET_KEY"),
            ("-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----", "PRIVATE_KEY"),
            ("postgres://app:pw@db.internal:5432/prod", "DATABASE_URL"),
            ("mysql://root:pw@localhost/app", "DATABASE_URL"),
            ("mongodb+srv://u:pw@cluster0.example.net/db", "MONGODB_URI"),
            ("redis://:pw@cache:6379/0", "REDIS_URL"),
            ("APP_DATABASE_URL=postgres://app:pw@db/prod", "APP_DATABASE_URL"),
            ("DATABASE_PASSWORD=hunter2hunter2", "DATABASE_PASSWORD"),
            ("Bearer " + String(repeating: "g", count: 32), nil),
            ("hunter2", nil),
        ]
        for (text, key) in cases {
            try expectEqual(SecretNaming.suggestion(forPlaintext: text, namespace: nil), key, String(text.prefix(12)))
        }
        try expectEqual(SecretNaming.suggestion(for: .githubPat, namespace: nil), "GITHUB_TOKEN")
        try expectEqual(SecretNaming.suggestion(for: .connectionString, namespace: nil), "DATABASE_URL", "scheme unknown once the value is in jt")
        try expectEqual(SecretNaming.suggestion(for: .jwt, namespace: nil), nil)
    }

    static func testComposition() throws {
        try expectEqual(SecretNaming.suggestion(forPlaintext: openAIKey, namespace: "myapp"), "myapp/OPENAI_API_KEY")
        try expectEqual(SecretNaming.suggestion(forPlaintext: "hunter2", namespace: "myapp"), "myapp/")
        try expectEqual(SecretNaming.suggestion(forPlaintext: openAIKey, namespace: nil), "OPENAI_API_KEY")
        try expectEqual(SecretNaming.suggestion(forPlaintext: "hunter2", namespace: nil), nil)
        try expectEqual(SecretNaming.suggestion(for: .githubPat, namespace: "infra"), "infra/GITHUB_TOKEN")
        try expectEqual(SecretNaming.suggestion(for: nil, namespace: "infra"), "infra/")
        try expectEqual(SecretNaming.suggestion(for: nil, namespace: nil), nil)
    }

    static func testSelection() throws {
        try expect(SecretNaming.selectsWholeSuggestion("myapp/OPENAI_API_KEY"), "Enter accepts, typing replaces it all")
        try expect(SecretNaming.selectsWholeSuggestion("OPENAI_API_KEY"))
        try expect(!SecretNaming.selectsWholeSuggestion("myapp/"), "only a namespace: keep it and type the KEY")
    }

    static func testRecentNamespace() throws {
        func record(_ name: String, _ updated: String?) -> SecretRecord {
            SecretRecord(id: name, reference: "jt://secret/\(name)", name: name, preview: "ab****cd",
                         updatedAt: updated.flatMap { ISO8601DateFormatter().date(from: $0) })
        }
        let records = [
            record("cf/ZONE", "2026-09-01T00:00:00Z"),
            record("myapp/OPENAI_API_KEY", "2026-09-20T00:00:00Z"),
            record("jiantieban/1", "2026-09-27T00:00:00Z"),
            record("LOOSE_TOKEN", "2026-09-26T00:00:00Z"),
            record("old/KEY", nil),
        ]
        try expectEqual(SecretNaming.recentNamespace(in: records), "myapp", "default names / no namespace / no time are skipped")
        try expectEqual(SecretNaming.recentNamespace(in: []), nil)
        try expectEqual(SecretNaming.recentNamespace(in: [record("jiantieban/1", "2026-09-27T00:00:00Z")]), nil)
        let migrated = [record("zeta/A", "2026-09-22T10:00:00Z"), record("alpha/B", "2026-09-22T10:00:00Z")]
        try expectEqual(SecretNaming.recentNamespace(in: migrated), "alpha", "same second (bulk migration): first by name, stable")
    }

    private struct Fixture {
        let session: PanelSession
        let store: ClipStore
        let secrets: SecretManager
        let jt: FakeJT
    }

    /// 入库 texts（最后一条在最上面）。
    private static func make(_ texts: [String], seed: [(String, String)] = []) throws -> Fixture {
        let store = try ClipStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, text) in texts.enumerated() {
            try store.upsertText(text, at: base.addingTimeInterval(Double(i)))
        }
        let pasteback = PastebackCoordinator(permission: FakePermission(true), clipboard: RecordingClipboard(), sender: CountingSender(), scheduler: ManualScheduler())
        let (manager, jt) = try FakeJT.make(store: store)
        for (name, updated) in seed { try jt.seed(name: name, updatedAt: updated) }
        let session = PanelSession(store: store, secrets: manager, pasteback: pasteback, autoUnfoldLines: { 4 })
        session.open()
        return Fixture(session: session, store: store, secrets: manager, jt: jt)
    }

    private static func renameSuggestion(_ effects: [PanelEffect]) -> String?? {
        for effect in effects {
            if case .beginRename(_, let suggestion) = effect { return .some(suggestion) }
        }
        return .none
    }

    private static let seeded = [("cf/ZONE_ID", "2026-09-01T00:00:00Z"), ("myapp/ANTHROPIC_API_KEY", "2026-09-20T00:00:00Z")]

    static func testMarkSuggestsNamespace() throws {
        let f = try make(["hunter2-not-a-known-format", openAIKey], seed: seeded)
        try expectEqual(renameSuggestion(f.session.perform(.markSecret)), .some("myapp/OPENAI_API_KEY"))
        f.session.select(1)
        try expectEqual(renameSuggestion(f.session.perform(.markSecret)), .some("myapp/"), "unknown format: just the namespace")

        let empty = try make([openAIKey])
        try expectEqual(renameSuggestion(empty.session.perform(.markSecret)), .some("OPENAI_API_KEY"), "empty jt: no namespace")

        let broken = try make([openAIKey], seed: seeded)
        broken.jt.failing("ls", "vault is locked")
        let effects = broken.session.perform(.markSecret)
        try expectEqual(renameSuggestion(effects), .some("OPENAI_API_KEY"), "jt unreadable: no namespace, marking still works: \(effects)")
        try expect(broken.session.items[0].isSecret)
    }

    static func testNoNameKeepsDefault() throws {
        let f = try make([openAIKey], seed: seeded)
        let id = f.session.items[0].id
        _ = f.session.perform(.markSecret) // 命名框里按 Esc：不调 rename
        try expectEqual(try f.store.item(id: id)?.secretName, SecretNaming.defaultName(forItemID: id))
        f.session.setSearchText(":secret ")
        let record = try unwrap(f.session.secretRecords.first { SecretNaming.isDefault($0.name) })
        try expectEqual(record.displayTitle, "未命名密钥")

        let g = try make([openAIKey], seed: seeded)
        let effects = g.session.perform(.pasteAsSecret)
        try expectEqual(renameSuggestion(effects), .none, "⌘⇧↩ pastes the reference right away: \(effects)")
        try expect(effects.contains(.hide), "\(effects)")
        try expectEqual(try g.store.item(id: g.session.items[0].id)?.secretName, SecretNaming.defaultName(forItemID: g.session.items[0].id))
    }

    static func testNamespaceUsesListingCache() throws {
        let f = try make([], seed: seeded)
        try expectEqual(f.secrets.recentNamespace(), "myapp")
        f.jt.resetCalls()
        try expectEqual(f.secrets.recentNamespace(), "myapp")
        try expectEqual(f.jt.calls, [], "unchanged vault: the last listing is reused")

        try f.jt.seed(name: "ops/RAILWAY_API_TOKEN", updatedAt: "2026-09-25T00:00:00Z")
        try expectEqual(f.secrets.recentNamespace(), "ops", "terminal jt add moves the vault: read again")
        try expectEqual(f.jt.commands, ["ls"])
    }

    static func testSecretViewRenameSuggestion() throws {
        let f = try make([openAIKey], seed: seeded)
        _ = f.session.perform(.markSecret)
        f.session.setSearchText(":secret ")
        let index = try unwrap(f.session.secretRecords.firstIndex { SecretNaming.isDefault($0.name) })
        f.jt.resetCalls()
        try expectEqual(renameSuggestion(f.session.perform(.rename, row: index)), .some("myapp/OPENAI_API_KEY"))
        try expectEqual(f.jt.calls, [], "the view already holds the listing")

        let named = try unwrap(f.session.secretRecords.firstIndex { $0.name == "cf/ZONE_ID" })
        try expectEqual(renameSuggestion(f.session.perform(.rename, row: named)), .some(nil), "already named: edit the name itself")
    }
}
