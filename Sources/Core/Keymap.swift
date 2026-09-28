/// 面板的键位表：动作 ↔ 按键组合的唯一出处。键盘分派、⌘ 提示条、右键菜单的快捷键都从这里读，不各写一份。
/// App 的动作只用 ⌘：⌃ 留给用户自己的导航层（如用键盘工具把 ⌃H/J/K/L 映射成方向键）和搜索框的文本编辑键。
///
/// ⌘1–⌘9（贴视口里第 n 条）和搜索框为空时的 ←/→（切换分类）按位置 / 状态生效，不是固定绑定，不在表里。

/// 所有可绑定的面板动作。rawValue 是设置里自定义键位的存储键：改名改 case，不改 rawValue，否则已保存的键位静默失效。
public enum PanelAction: String, CaseIterable, Hashable, Sendable {
    case paste            // 贴回（密钥行 = 贴引用）
    case pasteAsSecret    // 贴成密钥引用
    case pastePlaintext   // 密钥行显式贴明文
    case markSecret = "toggleSecret"  // 标记为密钥（ADR-0001 前是"标记 / 取消"开关）
    case rename           // 命名密钥
    case toggleExpand     // 展开 / 收起
    case openInEditor     // 打开（文本进编辑器，图片进看图 App）
    case openSource       // 回到浏览器原页面
    case toggleFavorite   // 收藏 / 取消收藏
    case delete           // 删除（可撤销）
    case undo = "undoDelete"          // 撤销刚才的删除或标记
    case moveUp
    case moveDown
    case jumpToFirst
    case jumpToLast
    case openSettings
    case close

    /// 作用于某一行的动作对应的会话命令；导航、撤销、设置、关闭由界面自己处理，返回 nil。
    public var command: PanelCommand? {
        switch self {
        case .paste: return .paste
        case .pasteAsSecret: return .pasteAsSecret
        case .pastePlaintext: return .pastePlaintext
        case .markSecret: return .markSecret
        case .rename: return .rename
        case .toggleExpand: return .toggleExpand
        case .openInEditor: return .openInEditor
        case .openSource: return .openSource
        case .toggleFavorite: return .toggleFavorite
        case .delete: return .delete
        case .undo, .moveUp, .moveDown, .jumpToFirst, .jumpToLast, .openSettings, .close: return nil
        }
    }
}

/// 键盘上的一个键。Core 不依赖 AppKit：界面负责把 NSEvent 翻译成它。
public enum Key: Hashable, Sendable {
    case `return`
    case escape
    case up
    case down
    case left
    case right
    /// 可打印字符键，一律存小写（`character("d")`、`character(",")`）。
    case character(Character)

    public static func char(_ c: Character) -> Key { .character(Character(c.lowercased())) }

    public var symbol: String {
        switch self {
        case .return: return "↩"
        case .escape: return "⎋"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .character(let c): return c.uppercased()
        }
    }
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// 一个按键组合：键 + 修饰键（⌘↩ 和 ⇧⌘↩ 是两个组合）。匹配规则见 Keymap.action(for:)。
public struct KeyCombo: Hashable, Sendable {
    public var key: Key
    public var modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// 显示用文字，如 `⌘D`、`⇧⌘↩`。修饰键按 Apple 的顺序 ⌃⌥⇧⌘：右键菜单由系统画，也是这个顺序，
    /// 同一个快捷键在提示条和菜单里写法一致。
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.symbol
    }

    /// 方向键、回车、Esc：它们的意思只由 ⌘ 改变。
    var isNavigation: Bool {
        if case .character = key { return false }
        return true
    }
}

/// 动作 → 按键组合。一个组合只属于一个动作；没有绑定的动作只能从菜单 / 鼠标触发。
public struct Keymap: Equatable, Sendable {
    public private(set) var bindings: [PanelAction: KeyCombo]

    public init(bindings: [PanelAction: KeyCombo]) {
        self.bindings = bindings
    }

    public static let defaults = Keymap(bindings: [
        .paste: KeyCombo(.return),
        .pasteAsSecret: KeyCombo(.return, .command),
        .pastePlaintext: KeyCombo(.return, [.command, .shift]),
        .markSecret: KeyCombo(.char("l"), .command),
        .rename: KeyCombo(.char("e"), .command),
        .toggleExpand: KeyCombo(.char("r"), .command),
        .openInEditor: KeyCombo(.char("o"), .command),
        .openSource: KeyCombo(.char("o"), [.option, .command]),
        .toggleFavorite: KeyCombo(.char("s"), .command),
        .delete: KeyCombo(.char("d"), .command),
        .undo: KeyCombo(.char("z"), .command),
        .moveUp: KeyCombo(.up),
        .moveDown: KeyCombo(.down),
        .jumpToFirst: KeyCombo(.up, .command),
        .jumpToLast: KeyCombo(.down, .command),
        .openSettings: KeyCombo(.char(","), .command),
        .close: KeyCombo(.escape),
    ])

    /// 外部覆盖（设置里自定义快捷键）：值为 nil 表示解绑。新组合原先属于别的动作时，那个动作被解绑，
    /// 保证一个组合只触发一个动作。
    public func overriding(_ overrides: [PanelAction: KeyCombo?]) -> Keymap {
        var result = self
        for (action, combo) in overrides {
            if let combo {
                for (other, existing) in result.bindings where other != action && existing == combo {
                    result.bindings[other] = nil
                }
            }
            result.bindings[action] = combo
        }
        return result
    }

    public func combo(for action: PanelAction) -> KeyCombo? {
        bindings[action]
    }

    /// 精确匹配优先。方向键、回车、Esc 没有精确绑定时，去掉 ⌃⌥⇧ 再找一次：
    /// 键盘工具把 ⌃J/⌃K 映射成 ↓/↑ 时，手上按着的 ⌃ 可能带进事件；以前 ⇧↓ 也能移动、⌥↩ 也能贴回。
    /// 字母键保持精确（⌘⌥D 不是删除）。
    public func action(for combo: KeyCombo) -> PanelAction? {
        if let exact = bindings.first(where: { $0.value == combo })?.key { return exact }
        guard combo.isNavigation else { return nil }
        let loose = KeyCombo(combo.key, combo.modifiers.intersection(.command))
        guard loose != combo else { return nil }
        return bindings.first { $0.value == loose }?.key
    }
}

// MARK: - 设置页：自定义快捷键

extension PanelAction {
    /// 设置页里的名字
    public var title: String {
        switch self {
        case .paste: return "贴回"
        case .pasteAsSecret: return "贴成密钥引用"
        case .pastePlaintext: return "贴密钥明文"
        case .markSecret: return "标记为密钥"
        case .rename: return "命名密钥"
        case .toggleExpand: return "展开 / 收起"
        case .openInEditor: return "打开"
        case .openSource: return "回到原页面"
        case .toggleFavorite: return "收藏 / 取消收藏"
        case .delete: return "删除"
        case .undo: return "撤销删除 / 标记"
        case .moveUp: return "上一条"
        case .moveDown: return "下一条"
        case .jumpToFirst: return "跳到第一条"
        case .jumpToLast: return "跳到最后一条"
        case .openSettings: return "打开设置"
        case .close: return "关闭面板"
        }
    }

    /// 设置页里能改的动作。↩ 贴回、Esc 关闭、↑↓ 移动是面板的基本操作，固定不改。
    public var isCustomizable: Bool {
        switch self {
        case .paste, .close, .moveUp, .moveDown: return false
        default: return true
        }
    }
}

extension KeyCombo {
    private static let modifierTokens: [(String, KeyModifiers)] = [("ctrl", .control), ("opt", .option), ("shift", .shift), ("cmd", .command)]
    private static let keyTokens: [(String, Key)] = [("return", .return), ("escape", .escape), ("up", .up), ("down", .down), ("left", .left), ("right", .right)]

    /// 存进设置的写法："cmd+shift+return"、"cmd+d"、"cmd+,"（最后一段是键，前面是修饰键）
    public var storageString: String {
        let mods = Self.modifierTokens.filter { modifiers.contains($0.1) }.map(\.0)
        let keyToken: String
        if case .character(let c) = key {
            keyToken = String(c)
        } else {
            keyToken = Self.keyTokens.first { $0.1 == key }?.0 ?? ""
        }
        return (mods + [keyToken]).joined(separator: "+")
    }

    public init?(storageString: String) {
        // 键本身可能是 "+"：从最后一个分隔符切开
        guard !storageString.isEmpty else { return nil }
        let keyPart: Substring
        var modifiers: KeyModifiers = []
        if storageString.hasSuffix("++") || storageString == "+" {
            keyPart = "+"
            let head = storageString.dropLast(storageString == "+" ? 1 : 2)
            for token in head.split(separator: "+") {
                guard let m = Self.modifierTokens.first(where: { $0.0 == token })?.1 else { return nil }
                modifiers.insert(m)
            }
        } else {
            let parts = storageString.split(separator: "+", omittingEmptySubsequences: false)
            guard let last = parts.last, !last.isEmpty else { return nil }
            keyPart = last
            for token in parts.dropLast() {
                guard let m = Self.modifierTokens.first(where: { $0.0 == token })?.1 else { return nil }
                modifiers.insert(m)
            }
        }
        if let named = Self.keyTokens.first(where: { $0.0 == keyPart })?.1 {
            self.init(named, modifiers)
        } else if keyPart.count == 1, let c = keyPart.first {
            self.init(.char(c), modifiers)
        } else {
            return nil
        }
    }
}

extension Keymap {
    /// 设置里存的覆盖（动作 rawValue → 组合写法，"" = 不设快捷键）叠到默认表上；认不出的条目、固定动作的条目忽略。
    public static func withStoredOverrides(_ stored: [String: String]) -> Keymap {
        var overrides: [PanelAction: KeyCombo?] = [:]
        for (raw, value) in stored {
            guard let action = PanelAction(rawValue: raw), action.isCustomizable else { continue }
            if value.isEmpty {
                overrides[action] = .some(nil)
            } else if let combo = KeyCombo(storageString: value), problem(with: combo) == nil {
                overrides[action] = combo
            }
        }
        // 固定动作的键不让覆盖抢走
        let fixed = Set(defaults.bindings.filter { !$0.key.isCustomizable }.map(\.value))
        return defaults.overriding(overrides.filter { $0.value.map { !fixed.contains($0) } ?? true })
    }

    /// 和默认表不同的部分，写回设置（没改过的动作不存，以后默认表变了能跟着变）。
    public var storedOverrides: [String: String] {
        var out: [String: String] = [:]
        for action in PanelAction.allCases where action.isCustomizable {
            let mine = combo(for: action)
            if mine != Keymap.defaults.combo(for: action) { out[action.rawValue] = mine?.storageString ?? "" }
        }
        return out
    }

    /// 给动作换这个组合前的检查：返回给用户看的原因，nil = 可以。
    /// reserved：App 自己在别处占用的组合（如唤醒热键）→ 说明。和别的动作撞了不算问题：换过来，那个动作解绑。
    public static func problem(with combo: KeyCombo, reserved: [KeyCombo: String] = [:]) -> String? {
        if let why = reserved[combo] { return "\(combo.display) 是\(why)" }
        let m = combo.modifiers
        guard !m.intersection([.command, .control, .option]).isEmpty else {
            return "要带 ⌘（或 ⌃、⌥）：单按的键会打进搜索框，↑↓ ↩ Esc 也已经有用处"
        }
        if m == .command, case .character(let c) = combo.key {
            switch c {
            case "a": return "⌘A 留给搜索框（全选）"
            case "c": return "⌘C 留给搜索框（拷贝）"
            case "v": return "⌘V 留给搜索框（粘贴）"
            case "x": return "⌘X 留给搜索框（剪切）"
            case "q": return "⌘Q 是退出 App"
            case "h": return "⌘H 是隐藏 App"
            case "w": return "⌘W 是关闭窗口"
            case "m": return "⌘M 是最小化窗口"
            case "1"..."9": return "⌘1–⌘9 用来贴视口里的第 n 条"
            default: break
            }
        }
        return nil
    }
}
