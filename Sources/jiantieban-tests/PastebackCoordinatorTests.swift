import Core
import Foundation

@MainActor
enum PastebackCoordinatorTests {
    private static func make(
        trusted: Bool
    ) -> (PastebackCoordinator, RecordingClipboard, CountingSender, ManualScheduler) {
        let clipboard = RecordingClipboard()
        let sender = CountingSender()
        let scheduler = ManualScheduler()
        let coordinator = PastebackCoordinator(
            permission: FakePermission(trusted),
            clipboard: clipboard,
            sender: sender,
            scheduler: scheduler
        )
        return (coordinator, clipboard, sender, scheduler)
    }

    static let all: [TestCase] = [
        TestCase("未授权的自动贴回不修改剪贴板也不发送按键") {
            let (coordinator, clipboard, sender, scheduler) = make(trusted: false)

            let result = coordinator.execute(.text("hello"), intent: .automaticPaste)

            try expectEqual(result, .needsAccessibility)
            try expectEqual(clipboard.contents, [])
            try expectEqual(scheduler.scheduleCount, 0)
            try expectEqual(sender.sendCount, 0)
        },
        TestCase("仅复制写入内容但不发送按键") {
            let (coordinator, clipboard, sender, scheduler) = make(trusted: false)

            let result = coordinator.execute(.text("hello"), intent: .copyOnly)

            try expectEqual(result, .copied)
            try expectEqual(clipboard.contents, [.text("hello")])
            try expectEqual(scheduler.scheduleCount, 0)
            try expectEqual(sender.sendCount, 0)
        },
        TestCase("已授权的自动贴回写入后只调度一次按键") {
            let (coordinator, clipboard, sender, scheduler) = make(trusted: true)

            let result = coordinator.execute(.secretReference("jt://secret/42"), intent: .automaticPaste)

            try expectEqual(result, .pasted)
            try expectEqual(clipboard.contents, [.secretReference("jt://secret/42")])
            try expectEqual(sender.sendCount, 0)
            try expectEqual(scheduler.scheduleCount, 1)
            scheduler.run()
            try expectEqual(sender.sendCount, 1)
        },
        TestCase("四类内容在仅复制模式都不调度按键") {
            let contents: [PastebackContent] = [
                .text("hello"),
                .image(path: "/tmp/image.png", asFile: false),
                .secretReference("jt://secret/42"),
                .secretPlaintext("secret"),
            ]
            for content in contents {
                let (coordinator, clipboard, sender, scheduler) = make(trusted: false)
                let result = coordinator.execute(
                    content,
                    intent: .copyOnly,
                    secretPlaintextConfirmed: content != .secretPlaintext("secret")
                )
                if content == .secretPlaintext("secret") {
                    try expectEqual(result, .secretPlaintextConfirmationRequired)
                    try expectEqual(clipboard.contents, [])
                } else {
                    try expectEqual(result, .copied)
                    try expectEqual(clipboard.contents, [content])
                }
                try expectEqual(scheduler.scheduleCount, 0)
                try expectEqual(sender.sendCount, 0)
            }
        },
        TestCase("确认后才允许仅复制密钥明文") {
            let (coordinator, clipboard, sender, scheduler) = make(trusted: false)

            let result = coordinator.execute(
                .secretPlaintext("secret"),
                intent: .copyOnly,
                secretPlaintextConfirmed: true
            )

            try expectEqual(result, .copied)
            try expectEqual(clipboard.contents, [.secretPlaintext("secret")])
            try expectEqual(scheduler.scheduleCount, 0)
            try expectEqual(sender.sendCount, 0)
        },
        TestCase("权限变化会实时切换当前模式") {
            let permission = FakePermission(false)
            let coordinator = PastebackCoordinator(
                permission: permission,
                clipboard: RecordingClipboard(),
                sender: CountingSender(),
                scheduler: ManualScheduler()
            )

            try expectEqual(coordinator.mode, .copyOnly)
            permission.isTrusted = true
            try expectEqual(coordinator.mode, .automaticPaste)
        },
        TestCase("复制密钥引用不得关面板，贴回仍关") {
            try expect(!PastebackResult.copied.hidesPanel(for: .secretReference("jt://secret/42")))
            try expect(PastebackResult.copied.hidesPanel(for: .text("hello")))
            try expect(PastebackResult.copied.hidesPanel(for: .secretPlaintext("secret")))
            try expect(PastebackResult.pasted.hidesPanel(for: .secretReference("jt://secret/42")))
            try expect(!PastebackResult.needsAccessibility.hidesPanel(for: .secretReference("jt://secret/42")))
        },
        TestCase("写入失败不会发送按键") {
            final class FailingClipboard: PastebackClipboardWriting {
                var changeCount: Int { 0 }
                func write(_ content: PastebackContent) -> Bool { false }
            }
            let sender = CountingSender()
            let scheduler = ManualScheduler()
            let coordinator = PastebackCoordinator(
                permission: FakePermission(true),
                clipboard: FailingClipboard(),
                sender: sender,
                scheduler: scheduler
            )

            let result = coordinator.execute(.image(path: "/missing", asFile: false), intent: .automaticPaste)

            try expectEqual(result, .contentUnavailable)
            try expectEqual(scheduler.scheduleCount, 0)
            try expectEqual(sender.sendCount, 0)
        },

        TestCase("延迟期间外部复制取消旧贴回及已贴回回调") {
            let (coordinator, clipboard, sender, scheduler) = make(trusted: true)
            let callbacks = CountingSender()
            coordinator.execute(.text("old"), intent: .automaticPaste) {
                callbacks.sendCommandV()
            }

            clipboard.changeCount += 1 // Another app replaces the clipboard.
            scheduler.run()

            try expectEqual(sender.sendCount, 0)
            try expectEqual(callbacks.sendCount, 0)
        },
        TestCase("剪贴板未变化时发送按键并执行已贴回回调") {
            let (coordinator, _, sender, scheduler) = make(trusted: true)
            let callbacks = CountingSender()
            coordinator.execute(.text("same"), intent: .automaticPaste) {
                callbacks.sendCommandV()
            }

            scheduler.run()

            try expectEqual(sender.sendCount, 1)
            try expectEqual(callbacks.sendCount, 1)
        },
        TestCase("较新的仅复制操作使旧贴回失效") {
            let (coordinator, clipboard, sender, scheduler) = make(trusted: true)
            let callbacks = CountingSender()
            coordinator.execute(.text("old"), intent: .automaticPaste) {
                callbacks.sendCommandV()
            }
            try expectEqual(coordinator.execute(.text("new"), intent: .copyOnly), .copied)

            scheduler.run()

            try expectEqual(clipboard.contents.last, .text("new"))
            try expectEqual(sender.sendCount, 0)
            try expectEqual(callbacks.sendCount, 0)
        },
        TestCase("连续自动贴回只发送最新请求并保留正确的剪贴板记录") {
            final class QueuedScheduler: PastebackScheduling {
                var actions: [@MainActor @Sendable () -> Void] = []
                func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
                    actions.append(action)
                }
            }
            let clipboard = RecordingClipboard()
            let sender = CountingSender()
            let scheduler = QueuedScheduler()
            let oldCallbacks = CountingSender()
            let newCallbacks = CountingSender()
            let coordinator = PastebackCoordinator(
                permission: FakePermission(true), clipboard: clipboard,
                sender: sender, scheduler: scheduler
            )
            coordinator.execute(.text("old"), intent: .automaticPaste) {
                oldCallbacks.sendCommandV()
            }
            coordinator.execute(.text("new"), intent: .automaticPaste) {
                newCallbacks.sendCommandV()
            }

            try expectEqual(scheduler.actions.count, 2)
            for action in scheduler.actions { action() }

            try expectEqual(sender.sendCount, 1)
            try expectEqual(oldCallbacks.sendCount, 0)
            try expectEqual(newCallbacks.sendCount, 1)
        },
    ]
}
