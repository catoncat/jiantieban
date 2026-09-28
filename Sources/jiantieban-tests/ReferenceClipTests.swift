import Core
import Foundation

/// 引用记录（剪贴板里标记过的那行）的名称和状态以 jt 为准（ADR-0001 / 03）：
/// 本地 secret_name / masked_preview 只是展示缓存，读到 jt 列表时刷新；jt 里删了就显示"密钥已删除"。
@MainActor
enum ReferenceClipTests {
    static let all: [TestCase] = [
        TestCase("进过密钥视图后，引用记录显示 jt 里的当前名称（终端改过名的也是），按新名能搜到", testListingRefreshesNames),
        TestCase("vault 文件变了才重读 jt：没变零调用；终端改名后下次刷新更新名称", testRefreshFollowsVaultChanges),
        TestCase("jt 里删了：标为已删除，贴 / 查看 / 改名提示不可用，只能删除，删除不调 jt rm", testMissingReferenceOnlyDeletes),
        TestCase("在密钥视图改名 / 删除：持有这个引用的剪贴板记录跟着更新", testSecretViewChangesReachClips),
        TestCase("引用记录上改名走 jt mv", testRenameReferenceClipGoesToJT),
        TestCase("jt 读失败不把引用当成已删除；jt 没装只探一次；没有引用记录时不调 jt", testFailuresKeepCache),
    ]

    private struct Fixture {
        let session: PanelSession
        let store: ClipStore
        let clipboard: RecordingClipboard
        let jt: FakeJT
    }

    private static let secretValue = "sk-" + String(repeating: "k", count: 40)

    /// 入库 texts（最后一条在最上面），把最上面那条标成密钥（默认名 jiantieban/<id>）。
    private static func makeMarked(_ texts: [String] = ["plain"], secrets: [String] = [], failingStatus: Bool = false) throws -> (Fixture, id: Int64, reference: String) {
        let store = try ClipStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, text) in (texts + [secretValue]).enumerated() {
            try store.upsertText(text, at: base.addingTimeInterval(Double(i)))
        }
        let clipboard = RecordingClipboard()
        let pasteback = PastebackCoordinator(permission: FakePermission(true), clipboard: clipboard, sender: CountingSender(), scheduler: ManualScheduler())
        let (manager, jt) = try FakeJT.make(store: store)
        for name in secrets { try jt.seed(name: name) }
        if failingStatus { jt.failing("status", "not installed") }
        let session = PanelSession(store: store, secrets: manager, pasteback: pasteback, autoUnfoldLines: { 4 })
        session.open()
        _ = session.perform(.markSecret)
        session.close() // 标记撤销失效
        session.open()
        let item = try unwrap(session.items.first)
        let f = Fixture(session: session, store: store, clipboard: clipboard, jt: jt)
        return (f, item.id, try unwrap(item.secretToken))
    }

    private static func clip(_ f: Fixture, _ id: Int64) throws -> ClipItem {
        try unwrap(try f.store.item(id: id), "item \(id) gone")
    }

    static func testListingRefreshesNames() throws {
        let (f, id, reference) = try makeMarked()
        try f.jt.renameOutside(reference, to: "ops/RAILWAY_API_TOKEN")
        try expectEqual(try clip(f, id).secretName, SecretNaming.defaultName(forItemID: id), "nothing read jt yet")

        f.session.setSearchText(":secret ")
        _ = f.session.setChip(.all, fieldText: "")
        try expectEqual(f.session.items.first?.displayTitle, "ops/RAILWAY_API_TOKEN")
        try expectEqual(try clip(f, id).maskedPreview, f.jt.preview(of: reference), "preview comes from jt too")
        f.session.setSearchText("RAILWAY")
        try expectEqual(f.session.items.map(\.id), [id], "the jt name is searchable in the timeline")
    }

    static func testRefreshFollowsVaultChanges() throws {
        let (f, id, reference) = try makeMarked()
        f.jt.resetCalls()
        f.session.open()
        try expectEqual(f.jt.calls, [], "opening never calls jt")

        _ = f.session.refreshReferences() // 标记之后 vault 变过：读一次列表（vault 在哪标记时已经问过）
        try expectEqual(f.jt.commands, ["ls"])
        f.jt.resetCalls()
        try expect(!f.session.refreshReferences())
        try expectEqual(f.jt.calls, [], "unchanged vault: just a stat")

        try f.jt.renameOutside(reference, to: "cf/API_TOKEN")
        try expect(f.session.refreshReferences(), "a changed name reloads the list")
        try expectEqual(f.jt.commands, ["ls"])
        try expectEqual(f.session.items.first { $0.id == id }?.secretName, "cf/API_TOKEN")
        f.jt.resetCalls()
        try expect(!f.session.refreshReferences())
        try expectEqual(f.jt.calls, [])

        f.session.setSearchText(":secret ")
        f.jt.resetCalls()
        try expect(!f.session.refreshReferences(), "the secret view is the jt listing already")
        try expectEqual(f.jt.calls, [])
    }

    static func testMissingReferenceOnlyDeletes() throws {
        let (f, id, reference) = try makeMarked()
        try f.jt.removeOutside(reference)
        try expect(f.session.refreshReferences())
        let item = try unwrap(f.session.items.first)
        try expectEqual(item.id, id)
        try expect(item.secretMissing)
        try expectEqual(ItemActions.available(for: item), [.delete])
        try expectEqual(f.session.hints.map(\.action), [.delete])

        let written = f.clipboard.contents.count
        f.jt.resetCalls()
        for command in [PanelCommand.paste, .pasteAsSecret, .pastePlaintext, .toggleExpand, .rename] {
            let effects = f.session.perform(command)
            try expectEqual(effects, [.beep, .toast("这条密钥已从 jt 删除 · 只能删除这条记录")], "\(command)")
        }
        try expectEqual(f.session.perform(.toggleFavorite), [])
        try expectEqual(f.clipboard.contents.count, written, "nothing reaches the clipboard")
        try expectEqual(f.session.expanded, nil)

        let deleted = f.session.perform(.delete)
        try expect(deleted.contains(.toast("已删除 · ⌘Z 撤销")), "\(deleted)")
        try expectEqual(try f.store.item(id: id), nil)
        try expectEqual(f.jt.calls, [], "deleting a reference clip never calls jt rm")
    }

    static func testSecretViewChangesReachClips() throws {
        let (f, id, reference) = try makeMarked(secrets: ["cf/ZONE"])
        f.session.setSearchText(":secret ")
        let recordID = reference.replacingOccurrences(of: "jt://secret/", with: "")
        _ = f.session.rename(row: .secret(recordID), to: "openai/KEY")
        try expectEqual(try clip(f, id).secretName, "openai/KEY")

        let index = try unwrap(f.session.index(of: .secret(recordID)))
        _ = f.session.perform(.delete, row: index)
        _ = f.session.perform(.delete, row: index)
        try expectEqual(f.jt.value(of: reference), nil)
        try expect(try clip(f, id).secretMissing, "the clip learns its secret is gone")

        _ = f.session.setChip(.all, fieldText: "")
        try expect(f.session.items.first { $0.id == id }?.secretMissing == true)
    }

    static func testRenameReferenceClipGoesToJT() throws {
        let (f, id, reference) = try makeMarked()
        try expectEqual(f.session.rename(row: .clip(id), to: "github/TOKEN"), [])
        try expectEqual(f.jt.name(of: reference), "github/TOKEN")
        try expectEqual(try clip(f, id).secretName, "github/TOKEN")
    }

    static func testFailuresKeepCache() throws {
        let (f, id, reference) = try makeMarked()
        _ = f.session.refreshReferences()
        try f.jt.removeOutside(reference)
        f.jt.failing("ls", "vault is locked")
        try expect(!f.session.refreshReferences())
        try expect(try clip(f, id).secretMissing == false, "a failed listing is not an empty vault")
        f.session.setSearchText(":secret ")
        _ = f.session.setChip(.all, fieldText: "")
        try expect(try clip(f, id).secretMissing == false)
        f.jt.failing("ls", nil)
        try expect(f.session.refreshReferences(), "retried on the next refresh")
        try expect(try clip(f, id).secretMissing)

        let (g, _, _) = try makeMarked(failingStatus: true)
        try expectEqual(g.jt.commands.filter { $0 == "status" }.count, 1, "probed once while marking")
        g.jt.resetCalls()
        _ = g.session.refreshReferences()
        _ = g.session.refreshReferences()
        try expectEqual(g.jt.calls, [], "a jt that can't tell where its vault is isn't asked again on every open")

        let store = try ClipStore()
        try store.upsertText("just text")
        let pasteback = PastebackCoordinator(permission: FakePermission(true), clipboard: RecordingClipboard(), sender: CountingSender(), scheduler: ManualScheduler())
        let (manager, jt) = try FakeJT.make(store: store)
        let session = PanelSession(store: store, secrets: manager, pasteback: pasteback, autoUnfoldLines: { 4 })
        session.open()
        try expect(!session.refreshReferences())
        try expectEqual(jt.calls, [], "no reference clips, no jt")
    }
}
