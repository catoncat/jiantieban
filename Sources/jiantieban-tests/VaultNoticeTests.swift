import Core
import Foundation

/// 密钥视图提示 vault 有未同步的改动（ADR-0001 / 07）：App 在 jt 里改名 / 删除 / 标记，但从不 `jt sync`，
/// 有没提交或没推送的改动时顶栏下提醒用户去终端同步。jt status 由界面在后台问，这里直接同步交回。
@MainActor
enum VaultNoticeTests {
    static let all: [TestCase] = [
        TestCase("进密钥视图后要一次 vault 状态：有没提交或没推送的改动时提示去终端 jt sync", testNoticeOnUnsyncedChanges),
        TestCase("vault 不是 git 仓库、已同步、jt status 失败：不提示", testNoNoticeOtherwise),
        TestCase("改名 / 删除后重新要；过期的回答、离开视图后才到的回答丢掉；离开视图提示消失", testRequestsFollowChanges),
        TestCase("App 从不执行 jt sync：标记、撤销、改名、列出、贴出、查看、删除、刷新、问状态都只用这几个命令", testNeverSyncs),
    ]

    private static let unsynced = "有未同步的改动 · 在终端运行 jt sync"

    private struct Fixture {
        let session: PanelSession
        let manager: SecretManager
        let store: ClipStore
        let jt: FakeJT
    }

    private static func make(_ texts: [String] = [], secrets: [String] = ["cf/ZONE", "openai/KEY"]) throws -> Fixture {
        let store = try ClipStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, text) in texts.enumerated() {
            try store.upsertText(text, at: base.addingTimeInterval(Double(i)))
        }
        let pasteback = PastebackCoordinator(permission: FakePermission(true), clipboard: RecordingClipboard(), sender: CountingSender(), scheduler: ManualScheduler())
        let (manager, jt) = try FakeJT.make(store: store)
        for name in secrets { try jt.seed(name: name) }
        let session = PanelSession(store: store, secrets: manager, pasteback: pasteback, autoUnfoldLines: { 4 })
        session.open()
        return Fixture(session: session, manager: manager, store: store, jt: jt)
    }

    private static func status(git: Bool, dirty: Bool, ahead: Int?) -> String {
        #"{"vault":"/tmp/v","key":"/tmp/v/key","git":\#(git),"dirty":\#(dirty),"ahead":\#(ahead.map(String.init) ?? "null")}"#
    }

    /// 界面做的事：取走请求，问 jt status，交回。
    @discardableResult
    private static func answer(_ f: Fixture) throws -> Bool {
        let request = try unwrap(f.session.takeVaultStatusRequest(), "no vault status request")
        return f.session.setVaultStatus(try? f.manager.fetchVaultStatus(), request: request)
    }

    static func testNoticeOnUnsyncedChanges() throws {
        let f = try make()
        f.jt.setStatus(status(git: true, dirty: true, ahead: 0))
        try expectEqual(f.session.takeVaultStatusRequest(), nil, "the timeline never asks")

        f.jt.resetCalls()
        f.session.setSearchText(":secret ")
        try expectEqual(f.jt.commands, ["ls"], "entering lists; status is asked off the main thread by the UI")
        try expectEqual(f.session.vaultNotice, nil)
        try expect(try answer(f))
        try expectEqual(f.session.vaultNotice, unsynced)
        try expectEqual(f.session.takeVaultStatusRequest(), nil, "one request per entry")
        f.session.setSearchText(":secret cf")
        try expectEqual(f.session.takeVaultStatusRequest(), nil, "a keyword change filters locally")
        try expectEqual(f.session.vaultNotice, unsynced, "and keeps the notice")

        let ahead = try make()
        ahead.jt.setStatus(status(git: true, dirty: false, ahead: 1))
        ahead.session.setSearchText(":secret ")
        try answer(ahead)
        try expectEqual(ahead.session.vaultNotice, unsynced, "committed but not pushed")
    }

    static func testNoNoticeOtherwise() throws {
        let f = try make()
        for json in [nil, status(git: true, dirty: false, ahead: 0), status(git: true, dirty: false, ahead: nil), status(git: false, dirty: true, ahead: 3)] {
            f.jt.setStatus(json)
            f.session.setSearchText(":secret ")
            try expect(!(try answer(f)))
            try expectEqual(f.session.vaultNotice, nil, json ?? "default status")
            _ = f.session.setChip(.all, fieldText: "")
        }

        f.jt.failing("status", "not a vault")
        f.session.setSearchText(":secret ")
        try answer(f)
        try expectEqual(f.session.vaultNotice, nil, "a failing jt status says nothing")

        let broken = try make()
        broken.jt.failing("ls", "vault is locked")
        broken.session.setSearchText(":secret ")
        try expectEqual(broken.session.takeVaultStatusRequest(), nil, "jt can't list: the empty state explains, no status")
    }

    static func testRequestsFollowChanges() throws {
        let f = try make()
        f.jt.setStatus(status(git: true, dirty: false, ahead: 0))
        f.session.setSearchText(":secret ")
        let first = try unwrap(f.session.takeVaultStatusRequest())

        let record = try unwrap(f.session.secretRecords.first { $0.name == "cf/ZONE" })
        _ = f.session.rename(row: .secret(record.id), to: "cf/ZONE_ID")
        f.jt.setStatus(status(git: true, dirty: true, ahead: 0))
        let afterRename = try unwrap(f.session.takeVaultStatusRequest(), "a rename asks again")
        try expect(!f.session.setVaultStatus(JTVaultStatus(vault: "/tmp/v", git: true, dirty: false, ahead: 0), request: first))
        try expect(f.session.setVaultStatus(try f.manager.fetchVaultStatus(), request: afterRename))
        try expectEqual(f.session.vaultNotice, unsynced)
        try expect(!f.session.setVaultStatus(try f.manager.fetchVaultStatus(), request: first), "a stale answer is dropped")
        try expectEqual(f.session.vaultNotice, unsynced)

        _ = f.session.rename(row: .secret(record.id), to: "cf/ZONE_ID")
        try expectEqual(f.session.takeVaultStatusRequest(), nil, "an unchanged name didn't touch the vault")

        let index = try unwrap(f.session.index(of: .secret(record.id)))
        _ = f.session.perform(.delete, row: index)
        try expectEqual(f.session.takeVaultStatusRequest(), nil, "armed, not deleted yet")
        _ = f.session.perform(.delete, row: index)
        let afterDelete = try unwrap(f.session.takeVaultStatusRequest(), "a delete asks again")

        _ = f.session.setChip(.all, fieldText: "")
        try expectEqual(f.session.vaultNotice, nil, "leaving the secret view hides the notice")
        try expect(!f.session.setVaultStatus(try f.manager.fetchVaultStatus(), request: afterDelete), "an answer arriving after leaving is dropped")
        try expectEqual(f.session.vaultNotice, nil)
        try expectEqual(f.session.takeVaultStatusRequest(), nil)

        f.session.setSearchText(":secret ")
        try answer(f)
        try expectEqual(f.session.vaultNotice, unsynced, "re-entering asks again")
        f.session.close()
        f.session.open()
        try expectEqual(f.session.vaultNotice, nil, "a fresh open starts in the timeline")
    }

    static func testNeverSyncs() throws {
        let key = "sk-" + String(repeating: "q", count: 40)
        let f = try make(["plain", key, "sk-" + String(repeating: "u", count: 40)])
        f.jt.setStatus(status(git: true, dirty: true, ahead: 2))

        _ = f.session.perform(.markSecret)
        _ = f.session.undo()
        f.session.select(1)
        _ = f.session.perform(.markSecret)
        f.session.close()
        f.session.open()
        let clip = try unwrap(f.session.items.first { $0.isSecret })
        _ = f.session.rename(row: .clip(clip.id), to: "openai/OPENAI_API_KEY")
        _ = f.session.refreshReferences()

        f.session.setSearchText(":secret ")
        try answer(f)
        let record = try unwrap(f.session.secretRecords.first)
        let index = try unwrap(f.session.index(of: .secret(record.id)))
        _ = f.session.perform(.pastePlaintext, row: index)
        _ = f.session.perform(.toggleExpand, row: index)
        _ = f.session.rename(row: .secret(record.id), to: "misc/RENAMED")
        try answer(f)
        _ = f.session.perform(.delete, row: index)
        _ = f.session.perform(.delete, row: index)
        try answer(f)
        _ = f.session.setChip(.all, fieldText: "")
        _ = f.session.refreshReferences()

        try expectEqual(f.session.vaultNotice, nil)
        try expect(!f.jt.commands.contains("sync"), "\(f.jt.commands)")
        try expectEqual(Set(f.jt.commands).subtracting(["add", "resolve", "rm", "mv", "ls", "status"]), [], "\(f.jt.commands)")
        try expect(Set(f.jt.commands).isSuperset(of: ["add", "resolve", "rm", "mv", "ls", "status"]), "the flow really exercised every path: \(f.jt.commands)")
    }
}
