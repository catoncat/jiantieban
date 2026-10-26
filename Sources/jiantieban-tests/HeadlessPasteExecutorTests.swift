import Core
import Foundation

@MainActor
enum HeadlessPasteExecutorTests {
    private final class Clipboard: PastebackClipboardWriting {
        var changeCount = 7
        var writes = 0
        var succeeds = true
        var mutateOnFailure = false
        func write(_ content: PastebackContent) -> Bool {
            writes += 1
            if succeeds || mutateOnFailure { changeCount += 1 }
            return succeeds
        }
    }

    private final class Permission: PastebackPermissionChecking {
        var isTrusted = true
    }

    private final class Fixture {
        let clipboard = Clipboard()
        let permission = Permission()
        var targetCurrent = true
        var released = true
        var sends = 0
        var sendSucceeds = true
        var time: TimeInterval = 0
        var waits = 0
        var onWait: (() -> Void)?

        func executor() -> HeadlessPasteExecutor {
            HeadlessPasteExecutor(
                permission: permission, clipboard: clipboard,
                targetIsCurrent: { self.targetCurrent },
                modifiersReleased: { self.released },
                sendCommandV: { self.sends += 1; return self.sendSucceeds },
                now: { self.time },
                wait: { duration in
                    self.time += duration
                    self.waits += 1
                    self.onWait?()
                }
            )
        }

        func expectFailure(_ code: String, changed: Bool = false, expectedCount: Int? = nil) throws {
            do {
                _ = try executor().execute(.text("test"), expectedClipboardChangeCount: expectedCount)
                throw TestFailure("Expected \(code)")
            } catch let error as HeadlessPasteError {
                try expectEqual(error.code, code)
                try expectEqual(error.clipboardChanged, changed)
            }
        }
    }

    static let all: [TestCase] = [
        TestCase("headless paste completes synchronously and reports only event_sent") {
            let f = Fixture()
            let result = try f.executor().execute(.text("test"), expectedClipboardChangeCount: 7)
            try expectEqual(result, .eventSent)
            try expectEqual(result.rawValue, "event_sent")
            try expectEqual(f.clipboard.writes, 1)
            try expectEqual(f.sends, 1)
            try expect(f.time >= 0.05)
        },
        TestCase("permission failure never writes or sends") {
            let f = Fixture()
            f.permission.isTrusted = false
            try f.expectFailure("accessibility_required")
            try expectEqual(f.clipboard.writes, 0)
            try expectEqual(f.sends, 0)
        },
        TestCase("stale request never overwrites a newer clipboard") {
            let f = Fixture()
            try f.expectFailure("clipboard_changed", expectedCount: 6)
            try expectEqual(f.clipboard.writes, 0)
            try expectEqual(f.sends, 0)
        },
        TestCase("headless paste waits for physical modifier release before writing") {
            let f = Fixture()
            f.released = false
            f.onWait = {
                if f.waits == 3 { f.released = true }
            }
            _ = try f.executor().execute(.text("test"))
            try expectEqual(f.waits, 4)
            try expectEqual(f.clipboard.writes, 1)
            try expectEqual(f.sends, 1)
        },
        TestCase("held modifiers time out without clipboard mutation") {
            let f = Fixture()
            f.released = false
            try f.expectFailure("modifiers_timeout")
            try expect(f.time >= 2 && f.time < 2.01)
            try expectEqual(f.clipboard.writes, 0)
            try expectEqual(f.sends, 0)
        },
        TestCase("foreground change during modifier wait aborts before write") {
            let f = Fixture()
            f.released = false
            f.onWait = { f.targetCurrent = false }
            try f.expectFailure("target_changed")
            try expectEqual(f.clipboard.writes, 0)
            try expectEqual(f.sends, 0)
        },
        TestCase("external copy during modifier wait aborts before write") {
            let f = Fixture()
            f.released = false
            f.onWait = { f.clipboard.changeCount += 1 }
            try f.expectFailure("clipboard_changed")
            try expectEqual(f.clipboard.writes, 0)
            try expectEqual(f.sends, 0)
        },
        TestCase("foreground change after write sends no key and reports mutation") {
            let f = Fixture()
            f.onWait = { f.targetCurrent = false }
            try f.expectFailure("target_changed", changed: true)
            try expectEqual(f.sends, 0)
        },
        TestCase("external copy after write is never pasted or restored over") {
            let f = Fixture()
            f.onWait = { f.clipboard.changeCount += 1 }
            try f.expectFailure("clipboard_changed", changed: true)
            try expectEqual(f.clipboard.writes, 1)
            try expectEqual(f.clipboard.changeCount, 9)
            try expectEqual(f.sends, 0)
        },
        TestCase("permission revoked after write sends no key and reports mutation") {
            let f = Fixture()
            f.onWait = { f.permission.isTrusted = false }
            try f.expectFailure("accessibility_required", changed: true)
            try expectEqual(f.sends, 0)
        },
        TestCase("modifiers pressed after write abort rather than send altered command") {
            let f = Fixture()
            f.onWait = { f.released = false }
            try f.expectFailure("modifiers_changed", changed: true)
            try expectEqual(f.sends, 0)
        },
        TestCase("clipboard write failure reports mutation accurately") {
            let f = Fixture()
            f.clipboard.succeeds = false
            try f.expectFailure("content_unavailable")
            try expectEqual(f.sends, 0)
            f.clipboard.mutateOnFailure = true
            try f.expectFailure("content_unavailable", changed: true)
            try expectEqual(f.sends, 0)
        },
        TestCase("event preparation failure is not reported as successful paste") {
            let f = Fixture()
            f.sendSucceeds = false
            try f.expectFailure("event_unavailable", changed: true)
            try expectEqual(f.sends, 1)
        },
    ]
}
