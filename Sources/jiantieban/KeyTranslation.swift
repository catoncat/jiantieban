import AppKit
import Carbon.HIToolbox
import Core

/// NSEvent / NSMenuItem 与 Core 键位表（KeyCombo）之间的翻译。键位本身只在 Core 的 Keymap 里定义。
@MainActor
enum KeyTranslation {
    /// 按键事件 → 组合。只看 ⌃⌥⇧⌘ 四个修饰键（方向键自带的 .function / .numericPad 不算）。
    static func combo(for event: NSEvent) -> KeyCombo? {
        let key: Key
        switch event.keyCode {
        case 36, 76: key = .return // 回车 / 小键盘回车
        case 53: key = .escape
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        default:
            // 按字符匹配（跟菜单快捷键一样随键盘布局走）；面板出现时已切到英文输入源
            guard let chars = event.charactersIgnoringModifiers, chars.count == 1, let c = chars.first else { return nil }
            key = .char(c)
        }
        return KeyCombo(key, modifiers(for: event.modifierFlags))
    }

    static func modifiers(for flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    /// RegisterEventHotKey 使用 Carbon 掩码，不能直接存 NSEvent.ModifierFlags.rawValue。
    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func modifierFlags(for modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { f.insert(.command) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.control) { f.insert(.control) }
        return f
    }

    /// NSMenuItem.keyEquivalent 用的字符串。
    static func keyEquivalent(for key: Key) -> String {
        switch key {
        case .return: return "\r"
        case .escape: return "\u{1b}"
        case .up: return functionKey(NSUpArrowFunctionKey)
        case .down: return functionKey(NSDownArrowFunctionKey)
        case .left: return functionKey(NSLeftArrowFunctionKey)
        case .right: return functionKey(NSRightArrowFunctionKey)
        case .character(let c): return String(c)
        }
    }

    /// 能输入到搜索框的字符：排除控制字符和方向键 / 功能键（私用区 U+F700–U+F8FF）。
    static func isPrintable(_ chars: String) -> Bool {
        chars.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private static func functionKey(_ code: Int) -> String {
        UnicodeScalar(code).map { String(Character($0)) } ?? ""
    }
}
