import Core
import Foundation

/// 面板规则：选中、刷新、展开、命令分派。走 PanelSession 的公开接口，用内存库 + 假 jt + 假剪贴板。
/// 每条对应一次真实坏过、或坏了代价大的行为。
@MainActor
enum PanelSessionTests {
    static let all: [TestCase] = [
        TestCase("搜索态 ⌘L 标记：条目不从结果里消失，仍选中并进入改名", testMarkInSearchKeepsRow),
        TestCase("图片上 ⌘L / ⌘↩ / ⌘E 什么都不做：不改库、不碰剪贴板、不报错", testImageIgnoresSecretCommands),
        TestCase("删除后选中停在原位置，删最后一行选中上移", testDeleteKeepsPosition),
        TestCase("剪贴板变化：无搜索词时新条目顶上来并选中，有搜索词不打断", testClipboardChange),
        TestCase("展开的行在选中离开、被标记后都会收起", testExpandedFollowsSelection),
        TestCase("贴回分派：密钥贴引用、普通贴原文；仅复制模式复制引用不关面板，⇧⌘↩ 复制明文", testPasteDispatch),
        TestCase("贴回按键发出后才永久保留，仅复制不会保留", testPasteMarksOnlyAfterDispatch),
        TestCase("撤销标记时明文又进了历史：合并成一行，列表不留被删的那行，选中不变", testUndoMarkMergeKeepsListConsistent),
        TestCase("出错 toast 是人话，不是 \"The operation couldn’t be completed\"", testErrorToastIsReadable),
        TestCase("命名推荐：认不出的密钥不预填；⌘E 未命名按存下的类型推荐，已命名不推荐", testRenameSuggestion),
        TestCase("密钥行 ⌘O 什么都不做：明文不交给编辑器（不写临时文件）", testSecretIsNotOpenedInEditor),
        TestCase("⌘D 删除后 ⌘Z：放回原位置并选中，id / 内容 / 收藏 / 时间 / OCR 都不变", testUndoDeleteRestoresInPlace),
        TestCase("撤销失效：面板关闭（图片文件这时才删）、再删另一条、搜索词变化", testUndoExpires),
        TestCase("没有可撤销的删除时 ⌘Z 不被面板吃掉（交给搜索框做文字撤销）", testUndoWithoutDeletionIsUnhandled),
        TestCase("⌘L 标记提示可撤销；⌘Z：明文放回原行并选中，jt 里刚建的那条删掉", testUndoMarkRestoresPlaintext),
        TestCase("标记撤销失效：面板关闭、切换筛选、改搜索词、再标记 / 删除一条；⌘⇧↩ 加密贴出不给撤销", testUndoMarkExpires),
        TestCase("引用记录上 ⌘L 什么都不做：没有取消密钥", testMarkOnReferenceIsNoop),
        TestCase("撤销标记时 jt 取不回真值：报错，密钥原样可用", testUndoMarkFailureKeepsSecret),
        TestCase("删除密钥行只删本地记录，jt 里的真值还在", testDeleteSecretKeepsVaultValue),
        TestCase("删除后新记录复用了同一个 id：撤销报错，不覆盖新记录", testUndoConflictDoesNotOverwrite),
        TestCase("自动展开：移动中（含刚打开）不展开，停下后普通文本展开 N 行，再移动立即收回", testAutoUnfoldWaitsForSettle),
        TestCase("密钥、图片停下也不自动展开；⌘R 仍是明文 + 引用 / 大图", testSecretAndImageDoNotAutoUnfold),
        TestCase("⌘R 在「展开全部」和「停下时的展开」之间切换；移动中按 ⌘R 也算停下", testToggleExpandSwitchesLayers),
        TestCase("N = 0：停下不自动展开，⌘R 仍能展开全部", testAutoUnfoldDisabled),
        TestCase("浏览器来源只在主动展开时提示，回原页不改剪贴板", testSourceOnlyOnExplicitExpand),
    ]

    private struct Fixture {
        let session: PanelSession
        let store: ClipStore
        let clipboard: RecordingClipboard
        let scheduler: ManualScheduler
        let permission: FakePermission
        let secrets: SecretManager
        let jt: FakeJT
    }

    /// texts 按顺序入库（后入库的更新），列表里倒序显示。
    private static func make(_ texts: [String], autoUnfoldLines: Int = 4) throws -> Fixture {
        let store = try ClipStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, text) in texts.enumerated() {
            try store.upsertText(text, at: base.addingTimeInterval(Double(i)))
        }
        let clipboard = RecordingClipboard()
        let permission = FakePermission(true)
        let scheduler = ManualScheduler()
        let pasteback = PastebackCoordinator(permission: permission, clipboard: clipboard, sender: CountingSender(), scheduler: scheduler)
        let (secrets, jt) = try FakeJT.make(store: store)
        let session = PanelSession(store: store, secrets: secrets, pasteback: pasteback, autoUnfoldLines: { autoUnfoldLines })
        session.open()
        return Fixture(session: session, store: store, clipboard: clipboard, scheduler: scheduler, permission: permission, secrets: secrets, jt: jt)
    }

    /// 真实存在的图片文件（原图 + 缩略图），用来验证文件什么时候被删。
    private static func addImage(_ f: Fixture, hash: String, at seconds: Double) throws -> ClipItem {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jtb-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("img.png").path
        let thumb = dir.appendingPathComponent("thumb.png").path
        for path in [image, thumb] { try Data([0x89, 0x50]).write(to: URL(fileURLWithPath: path)) }
        return try f.store.upsertImage(imagePath: image, thumbPath: thumb, hash: hash, at: Date(timeIntervalSince1970: seconds)).item
    }

    private static func filesExist(_ item: ClipItem) -> Bool {
        [item.imagePath, item.thumbPath].compactMap { $0 }.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private static let deletedToast = PanelEffect.toast("已删除 · ⌘Z 撤销")
    private static let markedToast = PanelEffect.toast("已存为密钥 · ⌘Z 撤销")

    private static func hasToast(_ effects: [PanelEffect]) -> Bool {
        effects.contains { if case .toast = $0 { return true } else { return false } }
    }

    /// 回归：标记后内容变成引用、不再匹配关键词，旧实现整表重搜让它消失，随后的改名找不到行（"⌘L 没反应"）。
    static func testMarkInSearchKeepsRow() throws {
        let f = try make(["meeting notes", "sk-live-" + String(repeating: "k", count: 30), "sk-other-" + String(repeating: "z", count: 30)])
        f.session.setSearchText("sk-live")
        try expectEqual(f.session.items.count, 1)
        let id = f.session.items[0].id

        let effects = f.session.perform(.markSecret)

        try expectEqual(effects, [markedToast, .beginRename(row: .clip(id), suggestion: "OPENAI_API_KEY")], "OpenAI-shaped key → name suggestion (empty jt: no namespace)")
        try expectEqual(f.session.items.map(\.id), [id], "marked row must stay in the results")
        try expect(f.session.items[0].isSecret)
        try expectEqual(f.session.selectedItem?.id, id)
    }

    static func testImageIgnoresSecretCommands() throws {
        let f = try make(["hello"])
        let (image, _) = try f.store.upsertImage(imagePath: "/tmp/jtb-none.png", thumbPath: "/tmp/jtb-none.png", hash: "h1", at: Date(timeIntervalSince1970: 1_800_000_000))
        f.session.open()
        try expectEqual(f.session.selectedItem?.id, image.id)

        try expectEqual(f.session.perform(.markSecret), [])
        try expectEqual(f.session.perform(.pasteAsSecret), [])
        try expectEqual(f.session.perform(.rename), [])

        try expect(try f.store.item(id: image.id)?.isSecret == false)
        try expectEqual(f.clipboard.contents, [])
    }

    static func testDeleteKeepsPosition() throws {
        let f = try make(["a", "b", "c", "d"]) // 显示 d c b a
        f.session.select(1)

        try expectEqual(f.session.perform(.delete), [deletedToast])
        try expectEqual(f.session.items.map(\.content), ["d", "b", "a"])
        try expectEqual(f.session.selectedItem?.content, "b", "selection stays at the same position")

        f.session.select(2)
        _ = f.session.perform(.delete)
        try expectEqual(f.session.selectedItem?.content, "b", "deleting the last row moves selection up")
        try expectEqual(try f.store.count(), 2)
    }

    static func testClipboardChange() throws {
        let f = try make(["a", "b"]) // 显示 b a
        f.session.select(1)
        try f.store.upsertText("new", at: Date(timeIntervalSince1970: 1_800_000_000))

        try expect(f.session.clipboardDidChange(), "a new head resets selection to the top")
        try expectEqual(f.session.items.first?.content, "new")
        try expectEqual(f.session.selectedIndex, 0)

        // 自家写剪贴板（没有新行）：选中不动
        f.session.select(2)
        try expect(!f.session.clipboardDidChange())
        try expectEqual(f.session.selectedItem?.content, "a")

        // 搜索中：不打断
        f.session.setSearchText("a")
        let before = f.session.items.map(\.id)
        try f.store.upsertText("another", at: Date(timeIntervalSince1970: 1_900_000_000))
        try expect(!f.session.clipboardDidChange())
        try expectEqual(f.session.items.map(\.id), before)
    }

    static func testExpandedFollowsSelection() throws {
        let f = try make(["first", "second " + String(repeating: "x", count: 30)])
        let top = f.session.items[0]
        _ = f.session.perform(.toggleExpand)
        try expectEqual(f.session.expanded?.row, .clip(top.id))
        try expectEqual(f.session.expanded?.unfold, .all)

        f.session.move(1)
        try expect(f.session.expanded == nil, "moving the selection collapses")

        f.session.move(-1)
        _ = f.session.perform(.toggleExpand)
        _ = f.session.perform(.markSecret)
        try expect(f.session.expanded == nil, "marking collapses the now-stale body")
    }

    static func testPasteDispatch() throws {
        let secretValue = "sk-" + String(repeating: "q", count: 40)
        let f = try make(["plain text", secretValue]) // 显示 secret, plain
        _ = f.session.perform(.markSecret)
        let token = try unwrap(f.session.items[0].secretToken)

        try expectEqual(f.session.perform(.paste), [.hide])
        try expectEqual(f.clipboard.contents.last, .secretReference(token))
        try expectEqual(f.session.perform(.paste, row: 1), [.hide])
        try expectEqual(f.clipboard.contents.last, .text("plain text"))

        f.permission.isTrusted = false // 仅复制模式
        try expectEqual(f.session.perform(.paste), [], "copying a reference keeps the panel open")
        try expectEqual(f.clipboard.contents.last, .secretReference(token))
        let plain = f.session.perform(.paste, row: 1)
        try expect(plain.first == .hide && hasToast(plain))

        let revealed = f.session.perform(.pastePlaintext)
        try expect(revealed.first == .hide && hasToast(revealed))
        try expectEqual(f.clipboard.contents.last, .secretPlaintext(secretValue))
    }

    static func testPasteMarksOnlyAfterDispatch() throws {
        let f = try make(["copied only", "pasted"])
        let pastedID = f.session.items[0].id
        let copiedID = f.session.items[1].id
        try expectEqual(f.session.perform(.paste), [.hide])
        try expect(try f.store.item(id: pastedID)?.wasPasted == false, "调度前尚未发出贴回按键")
        f.scheduler.run()
        try expect(try f.store.item(id: pastedID)?.wasPasted == true)
        f.permission.isTrusted = false
        _ = f.session.perform(.paste, row: 1)
        try expect(try f.store.item(id: copiedID)?.wasPasted == false, "仅复制到系统剪贴板不能算贴回")
    }

    static func testUndoMarkMergeKeepsListConsistent() throws {
        let f = try make(["dup-value-xyz-123"])
        _ = f.session.perform(.markSecret)
        try f.store.upsertText("dup-value-xyz-123", at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = f.session.clipboardDidChange() // 列表：[新复制的明文, 密钥]；剪贴板变化不让撤销失效
        f.session.select(1)
        let secretId = f.session.items[1].id
        f.session.select(0)

        try expectEqual(f.session.undo(), [])

        try expectEqual(f.session.items.map(\.id), [secretId], "the merged-away duplicate must leave the list")
        try expectEqual(f.session.selectedItem?.id, secretId)
        try expect(f.session.selectedItem?.isSecret == false)
    }

    /// 回归：StoreError / SQLiteError 没实现 LocalizedError，toast 显示 "The operation couldn’t be completed. (Core.StoreError error 1.)"。
    static func testErrorToastIsReadable() throws {
        let f = try make(["gone soon"])
        _ = try f.store.delete(id: f.session.items[0].id) // 面板开着时被保留策略清掉

        let effects = f.session.perform(.markSecret)

        let toasts = effects.compactMap { effect -> String? in if case .toast(let text) = effect { return text } else { return nil } }
        try expectEqual(toasts.count, 1, "got \(effects)")
        try expect(!toasts[0].contains("couldn’t be completed") && !toasts[0].contains("error 1"), "unreadable toast: \(toasts[0])")
    }

    static func testRenameSuggestion() throws {
        let f = try make(["hunter2-not-a-known-format", "sk-" + String(repeating: "k", count: 40)])
        // 列表按时间倒序：第 0 行是 OpenAI 形状的 key，第 1 行是认不出格式的口令
        f.session.select(1)
        let plainId = f.session.items[1].id
        try expectEqual(f.session.perform(.markSecret), [markedToast, .beginRename(row: .clip(plainId), suggestion: nil)], "unknown format → empty field")

        f.session.select(0)
        let keyId = f.session.items[0].id
        _ = f.session.perform(.markSecret) // 标记，不起名（相当于改名时按 Esc）
        try expectEqual(f.session.perform(.rename), [.beginRename(row: .clip(keyId), suggestion: "OPENAI_API_KEY")], "⌘E on an unnamed secret uses the stored type")

        _ = f.session.rename(row: .clip(keyId), to: "OpenAI 生产")
        try expectEqual(f.session.perform(.rename), [.beginRename(row: .clip(keyId), suggestion: nil)], "already named → show the name, no suggestion")
    }

    static func testUndoDeleteRestoresInPlace() throws {
        let f = try make(["a", "b"])
        let image = try addImage(f, hash: "undo-1", at: 1_750_000_000)
        try f.store.setOCRText("发票 2026", forItemID: image.id)
        try f.store.toggleFavorite(id: image.id)
        try f.store.upsertText("newest", at: Date(timeIntervalSince1970: 1_800_000_000))
        f.session.open() // 显示 newest, image, b, a
        let original = try unwrap(try f.store.item(id: image.id))
        let order = f.session.items.map(\.id)
        f.session.select(1)

        try expectEqual(f.session.perform(.delete), [deletedToast])
        try expect(try f.store.item(id: image.id) == nil, "deleted from the store right away")
        try expect(filesExist(original), "image files wait until the undo expires")
        try expect(f.session.canUndo)

        try expectEqual(f.session.undo(), [])
        try expectEqual(f.session.items.map(\.id), order, "back at the original position")
        try expectEqual(f.session.selectedItem?.id, image.id)
        try expectEqual(try f.store.item(id: image.id), original, "every field unchanged")
        try expectEqual(f.session.items[1], original)
        try expect(!f.session.canUndo, "one undo per deletion")

        // 撤销后重新打开面板：库里的顺序也是原来的
        f.session.close()
        try expect(filesExist(original), "restored item keeps its files")
        f.session.open()
        try expectEqual(f.session.items.map(\.id), order)
    }

    static func testUndoExpires() throws {
        let f = try make(["a", "b"])
        let first = try addImage(f, hash: "expire-1", at: 1_800_000_000)
        let second = try addImage(f, hash: "expire-2", at: 1_800_000_001)
        f.session.open() // 显示 second, first, b, a

        // 面板关闭
        _ = f.session.perform(.delete) // second
        f.session.close()
        try expect(f.session.undo() == nil, "closing the panel ends the undo")
        try expect(!filesExist(second), "image files are removed once the undo expires")

        // 又删了另一条：只能撤销最近那条，前一条的文件被删
        f.session.open() // first, b, a
        _ = f.session.perform(.delete) // first
        _ = f.session.perform(.delete) // b
        try expect(!filesExist(first))
        try expectEqual(f.session.undo(), [])
        try expectEqual(f.session.items.map(\.content), ["b", "a"])
        try expect(f.session.undo() == nil)

        // 搜索词变化
        _ = f.session.perform(.delete) // b
        f.session.setSearchText("a")
        try expect(f.session.undo() == nil, "changing the search text ends the undo")
        try expectEqual(try f.store.count(), 1)
    }

    static func testUndoWithoutDeletionIsUnhandled() throws {
        let f = try make(["a"])
        try expectEqual(f.session.keymap.action(for: KeyCombo(.char("z"), .command)), .undo)
        try expect(!f.session.canUndo)
        try expect(f.session.undo() == nil, "nil = not handled, the key goes on to the search field")
        try expectEqual(f.session.items.map(\.content), ["a"])
    }

    static func testUndoMarkRestoresPlaintext() throws {
        let f = try make(["a", "plain-to-mark-123", "b"]) // 显示 b, plain, a
        f.session.select(1)
        let id = f.session.items[1].id

        try expectEqual(f.session.perform(.markSecret).first, markedToast)
        let token = try unwrap(f.session.items[1].secretToken)
        try expectEqual(f.jt.value(of: token), "plain-to-mark-123")
        try expect(f.session.canUndo)
        f.session.select(0) // 改名结束后选中挪走了也照样撤销那一条

        try expectEqual(f.session.undo(), [])
        try expectEqual(f.session.items.map(\.content), ["b", "plain-to-mark-123", "a"], "back in place as plain text")
        try expectEqual(f.session.selectedItem?.id, id)
        try expect(f.session.selectedItem?.isSecret == false)
        try expect(f.jt.value(of: token) == nil, "the jt record created by the mark is removed")
        try expect(!f.session.canUndo && f.session.undo() == nil, "one undo per mark")
    }

    static func testUndoMarkExpires() throws {
        let f = try make(["one-value-123", "two-value-456", "three-value-789"]) // 显示 three, two, one
        _ = f.session.perform(.markSecret)
        f.session.close()
        try expect(f.session.undo() == nil, "closing the panel ends the undo")

        f.session.open()
        f.session.select(1)
        _ = f.session.perform(.markSecret) // two
        _ = f.session.setChip(.text, fieldText: "")
        try expect(f.session.undo() == nil, "switching the filter ends the undo")

        _ = f.session.setChip(.all, fieldText: "")
        f.session.select(2)
        _ = f.session.perform(.markSecret) // one
        f.session.setSearchText("x")
        try expect(f.session.undo() == nil, "changing the search text ends the undo")

        let g = try make(["p-value-123", "q-value-456"]) // 显示 q, p
        _ = g.session.perform(.markSecret) // q
        g.session.select(1)
        _ = g.session.perform(.markSecret) // p：只撤销最近这次
        try expectEqual(g.session.undo(), [])
        try expectEqual(g.session.items.map(\.isSecret), [true, false], "only the latest mark is undone")
        try expect(g.session.undo() == nil)

        _ = g.session.perform(.markSecret, row: 1) // 再标 p
        _ = g.session.perform(.delete, row: 0) // 删掉 q
        try expectEqual(g.session.undo(), [], "the delete is what gets undone")
        try expectEqual(g.session.items.map(\.isSecret), [true, true], "the mark before the delete stays")

        let h = try make(["r-value-123"])
        _ = h.session.perform(.pasteAsSecret)
        try expect(!h.session.canUndo, "paste as secret hides the panel and has no undo")
    }

    static func testMarkOnReferenceIsNoop() throws {
        let f = try make(["sk-" + String(repeating: "m", count: 40)])
        _ = f.session.perform(.markSecret)
        _ = f.session.undo()
        _ = f.session.perform(.markSecret)
        let before = f.session.items
        f.jt.resetCalls()

        try expectEqual(f.session.perform(.markSecret), [])
        try expectEqual(f.session.items, before)
        try expectEqual(f.jt.calls, [], "no jt call, no unmark")
    }

    static func testUndoMarkFailureKeepsSecret() throws {
        let value = "sk-" + String(repeating: "f", count: 40)
        let f = try make([value])
        _ = f.session.perform(.markSecret)
        let secret = try unwrap(f.session.selectedItem)
        f.jt.failing("resolve", "vault locked")

        let effects = try unwrap(f.session.undo())
        try expect(effects.contains(.toast("jt command failed: vault locked")), "got \(effects)")
        try expect(f.session.selectedItem?.isSecret == true, "row stays a secret")
        f.jt.failing("resolve", nil)
        try expectEqual(try f.secrets.resolveValue(for: secret), value)
    }

    static func testDeleteSecretKeepsVaultValue() throws {
        let value = "sk-" + String(repeating: "v", count: 40)
        let f = try make([value])
        _ = f.session.perform(.markSecret)
        let secret = try unwrap(f.session.selectedItem)
        try expect(secret.isSecret)

        try expectEqual(f.session.perform(.delete), [deletedToast])
        f.session.close()

        try expect(try f.store.item(id: secret.id) == nil)
        try expectEqual(try f.secrets.resolveValue(for: secret), value, "the reference may be in use elsewhere")
    }

    static func testUndoConflictDoesNotOverwrite() throws {
        let f = try make(["a", "b"]) // 显示 b a；b 的 id 最大
        let deletedId = f.session.items[0].id
        _ = f.session.perform(.delete)
        // 面板开着时又进来一条：SQLite 复用最大 id
        let (fresh, _) = try f.store.upsertText("fresh", at: Date(timeIntervalSince1970: 1_800_000_000))
        try expectEqual(fresh.id, deletedId, "precondition: the id is reused")

        let effects = try unwrap(f.session.undo())
        try expect(hasToast(effects), "got \(effects)")
        try expectEqual(try f.store.item(id: deletedId)?.content, "fresh", "the new item is untouched")
        try expect(!f.session.canUndo)
    }

    // MARK: - 自动展开

    private static func unfold(_ f: Fixture) -> PanelSession.Expanded? { f.session.unfolded }

    /// 回归风险：按住方向键连续翻时每一行都展开会让下面的行一路跳；刚打开面板也一样要等停下。
    static func testAutoUnfoldWaitsForSettle() throws {
        let f = try make(["c1\nc2", "b1\nb2\nb3", "a1\na2\na3\na4\na5"]) // 显示 a b c
        let ids = f.session.items.map(\.id)
        try expect(unfold(f) == nil, "just opened: not settled yet")

        f.session.settle()
        try expectEqual(unfold(f), .init(row: .clip(ids[0]), unfold: .lines(4)))

        f.session.move(1)
        try expect(unfold(f) == nil, "moving collapses immediately")
        f.session.move(1)
        try expect(unfold(f) == nil, "still moving: every row stays one line")

        f.session.settle()
        try expectEqual(unfold(f), .init(row: .clip(ids[2]), unfold: .lines(4)))

        f.session.move(1) // 到底了，选中没变：保持展开
        try expectEqual(unfold(f)?.row, .clip(ids[2]))

        f.session.open()
        try expect(unfold(f) == nil, "reopening waits for the first row to settle again")
    }

    static func testSecretAndImageDoNotAutoUnfold() throws {
        let secretValue = "sk-" + String(repeating: "s", count: 40)
        let f = try make(["plain\ntext", secretValue]) // 显示 secret, plain
        _ = f.session.perform(.markSecret)
        let secret = f.session.items[0]
        try expect(secret.isSecret)

        f.session.settle()
        try expect(unfold(f) == nil, "secret rows never auto-unfold")
        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f), .init(row: .clip(secret.id), unfold: .body(.text(secretValue + "\n\n" + (secret.secretToken ?? "")))))

        let (image, _) = try f.store.upsertImage(imagePath: "/tmp/jtb-none.png", thumbPath: "/tmp/jtb-none.png", hash: "h-unfold", at: Date(timeIntervalSince1970: 1_800_000_000))
        f.session.open()
        try expectEqual(f.session.selectedItem?.id, image.id)
        f.session.settle()
        try expect(unfold(f) == nil, "image rows never auto-unfold")
        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f), .init(row: .clip(image.id), unfold: .body(.image(path: "/tmp/jtb-none.png"))))
    }

    static func testToggleExpandSwitchesLayers() throws {
        let f = try make(["b", "a1\na2\na3\na4\na5\na6"])
        let top = f.session.items[0].id
        f.session.settle()

        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f), .init(row: .clip(top), unfold: .all))
        try expectEqual(f.session.hints.first { $0.key == "⌘R" }?.label, "收起")
        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f), .init(row: .clip(top), unfold: .lines(4)), "back to the settled unfold, not one line")

        // 连续移动中直接按 ⌘R：展开全部；再按回到停下时的展开
        f.session.move(1)
        f.session.move(-1)
        try expect(unfold(f) == nil, "coming back to the settled row still waits for a new settle")
        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f)?.unfold, .all)
        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f)?.unfold, .lines(4))

        _ = f.session.perform(.toggleExpand)
        f.session.move(1)
        try expect(unfold(f) == nil && f.session.expanded == nil, "leaving the row drops both layers")
    }

    static func testAutoUnfoldDisabled() throws {
        let f = try make(["a1\na2\na3"], autoUnfoldLines: 0)
        f.session.settle()
        try expect(unfold(f) == nil)
        _ = f.session.perform(.toggleExpand)
        try expectEqual(unfold(f)?.unfold, .all)
        _ = f.session.perform(.toggleExpand)
        try expect(unfold(f) == nil)
    }

    static func testSourceOnlyOnExplicitExpand() throws {
        let f = try make(["remember this line"])
        let item = try unwrap(f.session.selectedItem)
        let source = BrowserSource(bundleID: "com.google.Chrome", title: "Docs", url: "https://example.com/docs")
        try f.store.setBrowserSource(source, forItemID: item.id, copiedAt: item.lastCopiedAt)
        f.session.open()
        f.session.settle()
        try expectEqual(f.session.unfolded?.unfold, .lines(4), "停下只展开内容，不展示来源")
        try expect(f.session.hints.allSatisfy { $0.action != .openSource })
        try expectEqual(f.session.perform(.toggleExpand), [])
        try expectEqual(f.session.unfolded?.unfold, .all)
        try expect(f.session.hints.contains { $0.action == .openSource && $0.label == "原页" })
        try expectEqual(f.session.perform(.openSource), [.openSource(source)])
        try expectEqual(f.clipboard.contents, [], "回原页面不应触碰剪贴板")
    }

    /// 回归：以前 ⌘O（原 ⌃O）会向 jt 取明文、写进 $TMPDIR/jtb_clip_<id>.txt 交给编辑器，文件从不删除。
    static func testSecretIsNotOpenedInEditor() throws {
        let f = try make(["plain text", "sk-" + String(repeating: "o", count: 40)])
        _ = f.session.perform(.markSecret) // 第 0 行变成密钥
        try expect(f.session.items[0].isSecret)
        try expectEqual(f.session.perform(.openInEditor), [], "no hide, no open effect")

        f.session.select(1)
        let plain = f.session.items[1]
        try expectEqual(f.session.perform(.openInEditor), [.hide, .openInEditor(plain)], "plain text still opens")
    }
}
