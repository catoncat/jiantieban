import Core
import Foundation

/// 密钥视图 = jt 的全部记录（ADR-0001）：列出、分组、搜索、贴出、查看、改名、删除都落到 jt；
/// 普通面板路径一次都不调 jt。走 PanelSession 的公开接口，用内存库 + 假 jt + 假剪贴板。
@MainActor
enum SecretViewTests {
    static let all: [TestCase] = [
        TestCase("列出 jt 全部记录：按命名空间分组、组内按名称，未分组在最后；组标题只在每组第一行", testListsAndGroups),
        TestCase("本地的引用记录不重复出现：密钥视图只看 jt", testLocalReferenceIsNotDuplicated),
        TestCase("搜索只看名称，空格隔开的词都要出现，不分大小写；改关键词不重读 jt，重新进入才读", testSearchFiltersLocally),
        TestCase("贴出：⌘↩ 贴引用，⇧⌘↩ 贴明文；不往剪贴板历史写东西", testPasteReferenceAndPlaintext),
        TestCase("⌘R 查看：明文 + 引用，再按收起", testExpandShowsValueAndReference),
        TestCase("改名走 jt mv：换了命名空间就挪到新组，选中跟着走；名字没变不调 jt；重名报错", testRenameGoesToJT),
        TestCase("删除要按两次，落到 jt rm，没有撤销；移开选中或改关键词就要重新确认", testDeleteNeedsConfirmation),
        TestCase("收藏 / 打开 / 原页 / 标记对 jt 记录什么都不做也不调 jt；⌘ 提示只列可用的", testUnavailableActionsAreNoops),
        TestCase("读不到 jt：给出原因、列表为空；改关键词再试", testListFailureIsReported),
        TestCase("普通面板路径零 jt 调用：打开、搜索、:text / :img / :fav、移动、剪贴板变化", testClipboardPathsNeverCallJT),
        TestCase("行标题：默认名显示「未命名密钥」，有命名空间只显示后半段", testDisplayTitle),
        TestCase("解析 jt ls --json：旧条目时间是 null", testDecodeNullTimestamps),
    ]

    private struct Fixture {
        let session: PanelSession
        let store: ClipStore
        let clipboard: RecordingClipboard
        let permission: FakePermission
        let jt: FakeJT
    }

    /// texts 按顺序入库；secrets 按顺序写进假 vault（模拟终端 jt add 进来的记录）。
    private static func make(_ texts: [String] = [], secrets: [String] = []) throws -> Fixture {
        let store = try ClipStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, text) in texts.enumerated() {
            try store.upsertText(text, at: base.addingTimeInterval(Double(i)))
        }
        let clipboard = RecordingClipboard()
        let permission = FakePermission(true)
        let pasteback = PastebackCoordinator(permission: permission, clipboard: clipboard, sender: CountingSender(), scheduler: ManualScheduler())
        let (manager, jt) = try FakeJT.make(store: store)
        for name in secrets {
            try jt.seed(name: name, value: "value-of-\(name)")
        }
        let session = PanelSession(store: store, secrets: manager, pasteback: pasteback, autoUnfoldLines: { 4 })
        session.open()
        return Fixture(session: session, store: store, clipboard: clipboard, permission: permission, jt: jt)
    }

    private static func names(_ f: Fixture) -> [String] {
        f.session.rows.compactMap { $0.record?.name }
    }

    private static func select(_ f: Fixture, _ name: String) throws -> SecretRecord {
        let index = try unwrap(f.session.secretRecords.firstIndex { $0.name == name }, "no record \(name)")
        f.session.select(index)
        return f.session.secretRecords[index]
    }

    private static func toastText(_ effects: [PanelEffect]) -> String? {
        for effect in effects { if case .toast(let text) = effect { return text } }
        return nil
    }

    private static func isFailure(_ effects: [PanelEffect]) -> Bool {
        effects.first == .beep
    }

    static func testListsAndGroups() throws {
        let f = try make(secrets: ["openai/KEY", "LOOSE", "cf/ZONE", "Anthropic/api", "cf/API_TOKEN", "alpha"])
        f.session.setSearchText(":secret ")
        try expect(f.session.isSecretView)
        try expectEqual(names(f), ["Anthropic/api", "cf/API_TOKEN", "cf/ZONE", "openai/KEY", "alpha", "LOOSE"])
        try expectEqual(f.session.rows.indices.map(f.session.groupHeader(at:)),
                        ["Anthropic", "cf", nil, "openai", "未分组", nil])
        try expectEqual(f.session.selectedIndex, 0)
        try expectEqual(f.session.selectedRow?.id, .secret(try unwrap(f.session.secretRecords.first?.id)))
        try expectEqual(f.session.items, [], "clipboard rows are not part of the secret view")
    }

    static func testLocalReferenceIsNotDuplicated() throws {
        let f = try make(["sk-" + String(repeating: "z", count: 40), "plain"], secrets: ["cf/API_TOKEN"])
        f.session.select(1)
        _ = f.session.perform(.markSecret) // 本地记录变成引用，jt 里多一条 jiantieban/<id>
        f.session.setSearchText(":secret ")
        try expectEqual(f.session.rowCount, 2)
        try expect(f.session.rows.allSatisfy { $0.record != nil }, "every row comes from jt")
        let marked = try unwrap(f.session.secretRecords.first { SecretNaming.isDefault($0.name) })
        try expectEqual(marked.displayTitle, "未命名密钥")
    }

    static func testSearchFiltersLocally() throws {
        let f = try make(secrets: ["cf/API_TOKEN", "cf/ZONE", "github/TOKEN"])
        f.jt.resetCalls()
        f.session.setSearchText(":secret token")
        try expectEqual(names(f), ["cf/API_TOKEN", "github/TOKEN"])
        f.session.setSearchText(":secret TOKEN cf")
        try expectEqual(names(f), ["cf/API_TOKEN"], "all words must match, case-insensitive")
        f.session.setSearchText(":secret nothing")
        try expectEqual(names(f), [])
        try expectEqual(f.jt.commands, ["ls"], "keyword changes filter the listing already read")

        _ = f.session.setChip(.all, fieldText: "") // 回剪贴板视图
        try expect(!f.session.isSecretView)
        try expectEqual(f.session.secretRecords, [])
        f.session.setSearchText(":secret ")
        try expectEqual(f.jt.commands, ["ls", "ls"], "re-entering the view reads jt again")
    }

    static func testPasteReferenceAndPlaintext() throws {
        let f = try make(["history"], secrets: ["cf/API_TOKEN"])
        f.session.setSearchText(":secret ")
        let record = try select(f, "cf/API_TOKEN")

        try expectEqual(f.session.perform(.paste), [.hide])
        try expectEqual(f.clipboard.contents.last, .secretReference(record.reference))
        try expectEqual(f.session.perform(.pasteAsSecret), [.hide], "⌘⇧↩ on a jt record is the reference too")
        try expectEqual(f.clipboard.contents.last, .secretReference(record.reference))

        let revealed = f.session.perform(.pastePlaintext)
        try expect(revealed.first == .hide, "\(revealed)")
        try expectEqual(f.clipboard.contents.last, .secretPlaintext("value-of-cf/API_TOKEN"))

        f.permission.isTrusted = false
        try expectEqual(f.session.perform(.paste), [], "copying a reference keeps the panel open")
        try expectEqual(try f.store.search(SearchQuery(), page: 1, pageSize: 10).items.map(\.content), ["history"])
    }

    static func testExpandShowsValueAndReference() throws {
        let f = try make(secrets: ["cf/API_TOKEN", "cf/ZONE"])
        f.session.setSearchText(":secret ")
        let record = try select(f, "cf/ZONE")
        try expectEqual(f.session.perform(.toggleExpand), [])
        try expectEqual(f.session.expanded, .init(row: .secret(record.id), unfold: .body(.text("value-of-cf/ZONE\n\n" + record.reference))))
        try expectEqual(f.session.hints.first { $0.action == .toggleExpand }?.label, "收起")
        _ = f.session.perform(.toggleExpand)
        try expectEqual(f.session.expanded, nil)
        _ = f.session.perform(.toggleExpand)
        f.session.move(-1)
        try expectEqual(f.session.expanded, nil, "moving away folds the value")
    }

    static func testRenameGoesToJT() throws {
        let f = try make(secrets: ["cf/API_TOKEN", "cf/ZONE", "openai/KEY"])
        f.session.setSearchText(":secret ")
        let record = try select(f, "cf/ZONE")
        try expectEqual(f.session.perform(.rename), [.beginRename(row: .secret(record.id))])

        f.jt.resetCalls()
        try expectEqual(f.session.rename(row: .secret(record.id), to: "zeta/ZONE"), [])
        try expectEqual(f.jt.name(of: record.reference), "zeta/ZONE")
        try expectEqual(names(f), ["cf/API_TOKEN", "openai/KEY", "zeta/ZONE"])
        try expectEqual(f.session.selectedRecord?.id, record.id, "selection follows the renamed record")
        try expectEqual(f.session.groupHeader(at: 2), "zeta")

        f.jt.resetCalls()
        try expectEqual(f.session.rename(row: .secret(record.id), to: "zeta/ZONE"), [])
        try expectEqual(f.jt.calls, [], "unchanged name must not call jt mv (it would fail)")

        let clash = f.session.rename(row: .secret(record.id), to: "openai/KEY")
        try expect(isFailure(clash), "\(clash)")
        try expectEqual(f.jt.name(of: record.reference), "zeta/ZONE")
        try expectEqual(names(f), ["cf/API_TOKEN", "openai/KEY", "zeta/ZONE"])

        f.session.setSearchText(":secret zone")
        try expectEqual(names(f), ["zeta/ZONE"], "later searches see the new name without re-reading jt")
    }

    static func testDeleteNeedsConfirmation() throws {
        let f = try make(secrets: ["cf/API_TOKEN", "cf/ZONE", "openai/KEY"])
        f.session.setSearchText(":secret ")
        let record = try select(f, "cf/ZONE")
        f.jt.resetCalls()

        let armed = f.session.perform(.delete)
        try expectEqual(armed.count, 1)
        try expect(toastText(armed)?.contains("从 jt 删除「cf/ZONE」") == true, "\(armed)")
        try expectEqual(f.jt.calls, [], "first press only asks")

        f.session.move(1)
        f.session.move(-1)
        _ = f.session.perform(.delete)
        try expectEqual(f.jt.calls, [], "moving away disarms")

        f.session.setSearchText(":secret c")
        _ = try select(f, "cf/ZONE")
        _ = f.session.perform(.delete)
        try expectEqual(f.jt.calls, [], "keyword change disarms")
        f.session.setSearchText(":secret ")
        _ = try select(f, "cf/ZONE")

        _ = f.session.perform(.delete)
        _ = f.session.perform(.rename)
        _ = f.session.perform(.delete)
        try expectEqual(f.jt.calls, [], "another command in between disarms")

        let done = f.session.perform(.delete)
        try expectEqual(done, [.toast("已从 jt 删除「cf/ZONE」")])
        try expectEqual(f.jt.commands, ["rm"])
        try expectEqual(f.jt.value(of: record.reference), nil)
        try expectEqual(names(f), ["cf/API_TOKEN", "openai/KEY"])
        try expectEqual(f.session.selectedRecord?.name, "openai/KEY", "selection stays at the same position")
        try expectEqual(f.session.groupHeader(at: 1), "openai")
        try expect(!f.session.canUndo, "deleting from jt cannot be undone")
        try expect(f.session.undo() == nil)

        f.session.setSearchText(":secret zone")
        try expectEqual(names(f), [], "the deleted record is gone from the listing already read")
    }

    static func testUnavailableActionsAreNoops() throws {
        let f = try make(secrets: ["cf/API_TOKEN"])
        f.session.setSearchText(":secret ")
        f.jt.resetCalls()
        for command in [PanelCommand.markSecret, .toggleFavorite, .openInEditor, .openSource] {
            try expectEqual(f.session.perform(command), [], "\(command)")
        }
        try expectEqual(f.jt.calls, [])
        try expectEqual(Set(f.session.hints.map(\.action)), [.pastePlaintext, .rename, .toggleExpand, .delete])
        try expectEqual(f.session.hints.first { $0.action == .toggleExpand }?.label, "查看")
        let row = try unwrap(f.session.selectedRow)
        try expectEqual(ItemActions.available(for: row), [.paste, .pastePlaintext, .rename, .expand, .delete])
    }

    static func testListFailureIsReported() throws {
        let f = try make(secrets: ["cf/API_TOKEN"])
        f.jt.failing("ls", "vault is locked")
        f.session.setSearchText(":secret ")
        try expectEqual(f.session.rowCount, 0)
        let error = try unwrap(f.session.secretListError)
        try expect(error.contains("vault is locked"), error)
        try expectEqual(f.session.perform(.paste), [], "nothing selected, nothing happens")

        f.jt.failing("ls", nil)
        f.session.setSearchText(":secret cf")
        try expectEqual(f.session.secretListError, nil)
        try expectEqual(names(f), ["cf/API_TOKEN"])

        f.jt.failing("ls", "vault is locked")
        f.session.setSearchText(":secret c") // 已读到的列表不因之后的失败丢掉
        try expectEqual(names(f), ["cf/API_TOKEN"])
        _ = f.session.setChip(.all, fieldText: "")
        try expectEqual(f.session.secretListError, nil, "leaving the view clears the error")
    }

    static func testClipboardPathsNeverCallJT() throws {
        let f = try make(["alpha", "beta", "sk-" + String(repeating: "q", count: 40)], secrets: ["cf/API_TOKEN"])
        _ = f.session.perform(.markSecret) // 本地有一条引用记录
        f.jt.resetCalls()

        f.session.open()
        f.session.move(1)
        f.session.settle()
        f.session.move(-1)
        f.session.settle()
        _ = f.session.hints
        f.session.setSearchText("al")
        f.session.setSearchText(":text a")
        f.session.setSearchText(":img")
        f.session.setSearchText(":fav")
        _ = f.session.setChip(.all, fieldText: "")
        _ = f.session.cycleChip(1, fieldText: "")
        _ = f.session.setChip(.all, fieldText: "")
        try f.store.upsertText("gamma", at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = f.session.clipboardDidChange()
        f.session.close()
        try expectEqual(f.jt.calls, [], "the everyday panel must not spawn jt")
    }

    static func testDisplayTitle() throws {
        func record(_ name: String) -> SecretRecord {
            SecretRecord(id: "r", reference: "jt://secret/r", name: name, preview: "ab****wxyz")
        }
        try expectEqual(record("jiantieban/12").displayTitle, "未命名密钥")
        try expectEqual(record("jiantieban/12").userFacingName, nil)
        try expectEqual(record("jiantieban/12").groupTitle, "jiantieban")
        try expectEqual(record("cf/API_TOKEN").displayTitle, "API_TOKEN")
        try expectEqual(record("cf/API_TOKEN").userFacingName, "cf/API_TOKEN")
        try expectEqual(record("cf/a/b").displayTitle, "a/b")
        try expectEqual(record("cf/a/b").groupTitle, "cf")
        try expectEqual(record("LOOSE").displayTitle, "LOOSE")
        try expectEqual(record("LOOSE").groupTitle, "未分组")
        try expectEqual(record("cf/").displayTitle, "cf/")
        try expectEqual(record("/x").namespace, nil)
        try expectEqual(record("/x").displayTitle, "/x")
    }

    static func testDecodeNullTimestamps() throws {
        let json = """
        [{"id":"a1","ref":"jt://secret/a1","name":"old","preview":"ol****alue","created_at":null,"updated_at":null},
         {"id":"b2","ref":"jt://secret/b2","name":"cf/NEW","preview":"ne****alue","created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-02T11:30:00+08:00"}]
        """
        let records = try SecretRecords.decode(Data(json.utf8))
        try expectEqual(records.map(\.name), ["old", "cf/NEW"])
        try expectEqual(records[0].createdAt, nil)
        try expectEqual(records[0].updatedAt, nil)
        try expectEqual(records[1].createdAt, ISO8601DateFormatter().date(from: "2026-09-01T10:00:00Z"))
        try expectEqual(records[1].updatedAt, ISO8601DateFormatter().date(from: "2026-09-02T03:30:00Z"))
        do {
            _ = try SecretRecords.decode(Data("not json".utf8))
            throw TestFailure("expected invalid output to throw")
        } catch is DecodingError {}
    }
}
