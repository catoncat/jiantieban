import Core
import Foundation

/// 键位表是键盘、提示条、右键菜单的唯一出处。守住：App 动作不占 ⌃（用户的导航层 / 文本编辑键）；
/// 提示条显示的键永远等于真正生效的键（以前提示只列 ⌘ 的键，用户忘了 ⌃D 是删除）。
enum KeymapTests {
    static let all: [TestCase] = [
        TestCase("默认表不用 ⌃，一个组合只对应一个动作", testDefaultsAvoidControl),
        TestCase("提示条每项的按键文字与表一致（默认表和覆盖后的表）", testHintKeysMatchTable),
        TestCase("提示标签：按记录状态生成，统一两字", testHintLabels),
        TestCase("方向键 / 回车 / Esc 忽略 ⌃⌥⇧（键盘工具把 ⌃J 映射成的 ↓ 可能带着 ⌃），字母键保持精确", testNavigationIgnoresExtraModifiers),
        TestCase("自定义快捷键存取：写法可往返；只存改过的；解绑、换键、坏数据、抢固定键", testStoredOverrides),
        TestCase("动作改名不改存储键：已保存的 toggleSecret / undoDelete 键位仍然生效", testStorageKeysSurviveRenames),
        TestCase("换快捷键前的检查：不带 ⌘⌃⌥、搜索框的 ⌘A/C/V/X、⌘Q、⌘1–9、唤醒热键都不行", testAssignProblems),
    ]

    static let plain = ClipItem(kind: .text, content: "hello")
    static let secret = ClipItem(kind: .text, content: "jt://secret/x", isFavorite: true, isSecret: true, secretToken: "jt://secret/x", secretName: "OpenAI")
    static let image = ClipItem(kind: .image, content: "", imagePath: "/tmp/a.png", thumbPath: "/tmp/a-thumb.png")

    static func testDefaultsAvoidControl() throws {
        let keymap = Keymap.defaults
        for (action, combo) in keymap.bindings {
            try expect(!combo.modifiers.contains(.control), "\(action) is bound to \(combo.display)")
            try expectEqual(keymap.action(for: combo), action, "\(combo.display) is bound twice")
        }
        try expectEqual(keymap.combo(for: .delete)?.display, "⌘D")
        try expectEqual(keymap.combo(for: .undo)?.display, "⌘Z")
        try expectEqual(keymap.combo(for: .pastePlaintext)?.display, "⇧⌘↩", "Apple order ⌃⌥⇧⌘, same as the context menu")
        try expectEqual(keymap.combo(for: .openSettings)?.display, "⌘,")
        try expectEqual(keymap.action(for: KeyCombo(.char("D"), .command)), .delete, "letters are case-insensitive")
    }

    static func testHintKeysMatchTable() throws {
        // 覆盖：删除改到 ⌘S，原先占 ⌘S 的收藏被解绑；命名解绑
        let custom = Keymap.defaults.overriding([.delete: KeyCombo(.char("s"), .command), .rename: nil])
        try expect(custom.combo(for: .toggleFavorite) == nil, "the displaced action must be unbound")
        try expectEqual(custom.action(for: KeyCombo(.char("s"), .command)), .delete)

        for keymap in [Keymap.defaults, custom] {
            for item in [plain, secret, image] {
                for expanded in [false, true] {
                    for copyOnly in [false, true] {
                        for hint in ItemActions.hints(for: item, expanded: expanded, copyOnly: copyOnly, keymap: keymap) {
                            try expectEqual(hint.key, try unwrap(keymap.combo(for: hint.action)).display, "hint for \(hint.action)")
                        }
                    }
                }
            }
        }
        let customSecret = ItemActions.hints(for: secret, expanded: false, copyOnly: false, keymap: custom)
        try expect(!customSecret.contains { $0.action == .rename || $0.action == .toggleFavorite }, "unbound actions are not hinted")
        try expect(customSecret.contains { $0.key == "⌘S" && $0.label == "删除" })
    }

    /// 回归风险：精确匹配下，键盘工具用 ⌃J/⌃K 发出的方向键若带着 ⌃ 就移动不了；以前 ⇧↓、⌥↩ 也有效。
    static func testNavigationIgnoresExtraModifiers() throws {
        let k = Keymap.defaults
        try expectEqual(k.action(for: KeyCombo(.down, .control)), .moveDown)
        try expectEqual(k.action(for: KeyCombo(.up, [.control, .shift])), .moveUp)
        try expectEqual(k.action(for: KeyCombo(.down, [.control, .command])), .jumpToLast, "⌃⌘J → ⌘↓")
        try expectEqual(k.action(for: KeyCombo(.return, .option)), .paste)
        try expectEqual(k.action(for: KeyCombo(.return, [.command, .shift])), .pastePlaintext, "an exact binding still wins")
        try expectEqual(k.action(for: KeyCombo(.escape, .shift)), .close)
        try expect(k.action(for: KeyCombo(.char("d"), [.command, .option])) == nil, "letters stay exact")
        try expect(k.action(for: KeyCombo(.left, .control)) == nil, "unbound keys stay unbound")
    }

    static func testHintLabels() throws {
        func labels(_ item: ClipItem, expanded: Bool = false, copyOnly: Bool = false) -> [String] {
            ItemActions.hints(for: item, expanded: expanded, copyOnly: copyOnly).map(\.label)
        }
        try expectEqual(labels(plain), ["加密", "标记", "展开", "打开", "收藏", "删除"])
        try expectEqual(labels(secret), ["明文", "命名", "查看", "收藏", "删除"], "no 解除: there is no unmark")
        try expectEqual(labels(secret, copyOnly: true).first, "复制")
        try expectEqual(labels(image), ["预览", "打开", "收藏", "删除"])
        for item in [plain, secret, image] {
            for label in labels(item, expanded: true) { try expectEqual(label.count, 2, label) }
        }
    }

    /// 回归风险：设置存坏了 / 写法解析错了，面板的键就全乱了；默认表以后改了，没改过的动作要跟着变。
    static func testStoredOverrides() throws {
        for combo in [KeyCombo(.return, [.command, .shift]), KeyCombo(.char("d"), .command), KeyCombo(.char(","), .command),
                      KeyCombo(.char("+"), .command), KeyCombo(.up, [.option, .control])] {
            try expectEqual(KeyCombo(storageString: combo.storageString), combo, combo.storageString)
        }
        try expectEqual(KeyCombo(.return, [.command, .shift]).storageString, "shift+cmd+return")
        try expectEqual(Keymap.defaults.storedOverrides, [:], "nothing changed → nothing stored")

        let changed = Keymap.defaults.overriding([.toggleFavorite: KeyCombo(.char("d"), .command)]) // 抢走删除的 ⌘D
        try expectEqual(changed.storedOverrides, ["toggleFavorite": "cmd+d", "delete": ""])
        let loaded = Keymap.withStoredOverrides(changed.storedOverrides)
        try expectEqual(loaded, changed, "round trip through settings")
        try expect(loaded.combo(for: .delete) == nil)

        let messy = Keymap.withStoredOverrides([
            "rename": "cmd+shift+n",       // 正常
            "nonsense": "cmd+k",           // 没这个动作
            "delete": "cmd+",              // 写坏了
            "toggleExpand": "r",           // 不带修饰键：不合规，忽略
            "paste": "cmd+p",              // 固定动作不能改
            "openInEditor": "escape",      // 抢固定键：忽略（且不带修饰键）
            "toggleSecret": "cmd+down",    // 抢"跳到最后一条"：可以，那个动作解绑
        ])
        try expectEqual(messy.combo(for: .rename), KeyCombo(.char("n"), [.command, .shift]))
        try expectEqual(messy.combo(for: .delete), KeyCombo(.char("d"), .command), "broken entry keeps the default")
        try expectEqual(messy.combo(for: .toggleExpand), KeyCombo(.char("r"), .command))
        try expectEqual(messy.combo(for: .paste), KeyCombo(.return))
        try expectEqual(messy.combo(for: .close), KeyCombo(.escape))
        try expectEqual(messy.combo(for: .markSecret), KeyCombo(.down, .command), "old storage key toggleSecret still binds 标记为密钥")
        try expect(messy.combo(for: .jumpToLast) == nil)
    }

    /// 回归风险：ADR-0001 把"标记 / 取消"开关改成只标记、把撤销删除扩到撤销标记，case 改了名；
    /// rawValue 一变，用户在设置里改过的这两个键就静默回到默认。
    static func testStorageKeysSurviveRenames() throws {
        try expectEqual(PanelAction.markSecret.rawValue, "toggleSecret")
        try expectEqual(PanelAction.undo.rawValue, "undoDelete")
        let loaded = Keymap.withStoredOverrides(["toggleSecret": "cmd+shift+l", "undoDelete": "cmd+shift+z"])
        try expectEqual(loaded.combo(for: .markSecret), KeyCombo(.char("l"), [.command, .shift]))
        try expectEqual(loaded.combo(for: .undo), KeyCombo(.char("z"), [.command, .shift]))
    }

    static func testAssignProblems() throws {
        let hotkey = KeyCombo(.char("v"), [.command, .shift])
        let reserved = [hotkey: "唤醒面板的热键"]
        try expect(Keymap.problem(with: KeyCombo(.char("d")), reserved: reserved) != nil, "plain letters type into the search box")
        try expect(Keymap.problem(with: KeyCombo(.char("d"), .shift), reserved: reserved) != nil)
        try expect(Keymap.problem(with: KeyCombo(.up), reserved: reserved) != nil)
        try expectEqual(Keymap.problem(with: KeyCombo(.char("v"), .command)), "⌘V 留给搜索框（粘贴）")
        try expect(Keymap.problem(with: KeyCombo(.char("q"), .command)) != nil)
        try expect(Keymap.problem(with: KeyCombo(.char("3"), .command)) != nil)
        try expectEqual(Keymap.problem(with: hotkey, reserved: reserved), "⇧⌘V 是唤醒面板的热键")
        for ok in [KeyCombo(.char("d"), [.command, .shift]), KeyCombo(.up, .option), KeyCombo(.char("k"), .control), KeyCombo(.char("v"), [.command, .option])] {
            try expect(Keymap.problem(with: ok, reserved: reserved) == nil, ok.display)
        }
    }
}
