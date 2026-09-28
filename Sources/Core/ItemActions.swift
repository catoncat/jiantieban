/// 一条剪贴板记录"此刻能做什么"的唯一出处。
/// 键盘处理、右键菜单、⌘ 提示三处都只问这里，不再各自判断类型。按什么键见 Keymap。
public enum ItemAction: CaseIterable, Hashable {
    case paste            // 贴回（密钥行 = 贴引用）
    case pasteAsSecret    // 明文一步加密并贴引用
    case pastePlaintext   // 密钥行显式贴明文
    case markSecret       // 明文 → 密钥（没有反向：标错了靠标记后的撤销，见 ADR-0001）
    case rename
    case expand           // 全文 / 大图 / 明文
    case openInEditor
    case openSource
    case toggleFavorite
    case delete
}

/// 提示条里的一项：按键文字取自键位表，标签按记录状态生成。
public struct KeyHint: Equatable, Sendable {
    public let action: PanelAction
    public let key: String
    public let label: String
}

public enum ItemActions {
    public static func available(for item: ClipItem) -> Set<ItemAction> {
        let source: Set<ItemAction> = item.browserSource == nil ? [] : [.openSource]
        switch item.kind {
        case .image:
            return Set([.paste, .expand, .openInEditor, .toggleFavorite, .delete]).union(source)
        case .text where item.isSecret && item.secretMissing:
            // jt 里已经删了：引用贴出去也解析不了，只剩删掉这条记录
            return [.delete]
        case .text where item.isSecret:
            // 没有"打开"：交给编辑器就得把明文写进临时文件，还会进编辑器的最近文件 / 会话恢复。
            // 看明文用 ⌘R（只在面板里显示），要用就 ⇧⌘↩ 贴出去。
            return [.paste, .pastePlaintext, .rename, .expand, .toggleFavorite, .delete]
        case .text:
            return Set([.paste, .pasteAsSecret, .markSecret, .expand, .openInEditor, .toggleFavorite, .delete]).union(source)
        }
    }

    /// jt 里的密钥记录：没有收藏（那是剪贴板历史的保留规则）、没有打开 / 原页；删除落到 jt，没有撤销。
    public static func available(for record: SecretRecord) -> Set<ItemAction> {
        [.paste, .pastePlaintext, .rename, .expand, .delete]
    }

    public static func available(for row: PanelRow) -> Set<ItemAction> {
        switch row {
        case .clip(let item): return available(for: item)
        case .secret(let record): return available(for: record)
        }
    }

    public static func can(_ action: ItemAction, _ item: ClipItem) -> Bool {
        available(for: item).contains(action)
    }

    /// 按住 ⌘ 时的提示，按 PanelAction 的顺序列出；没绑键的动作不列。
    /// 提示条放不下时谁先让位：数值小的先去掉。删除最后才去——用户就是因为提示里没有它才忘了删除键。
    public static func hintPriority(_ action: PanelAction) -> Int {
        switch action {
        case .delete: return 100
        case .markSecret: return 90
        case .paste, .pasteAsSecret, .pastePlaintext: return 80
        case .rename: return 70
        case .toggleExpand: return 60
        case .openInEditor: return 50
        case .openSource: return 45
        case .toggleFavorite: return 40
        case .undo, .moveUp, .moveDown, .jumpToFirst, .jumpToLast, .openSettings, .close: return 0
        }
    }

    public static func hints(for item: ClipItem, expanded: Bool, copyOnly: Bool, keymap: Keymap = .defaults) -> [KeyHint] {
        hints(for: .clip(item), expanded: expanded, copyOnly: copyOnly, keymap: keymap)
    }

    public static func hints(for row: PanelRow, expanded: Bool, copyOnly: Bool, keymap: Keymap = .defaults) -> [KeyHint] {
        PanelAction.allCases.compactMap { action in
            guard let label = hintLabel(for: action, row: row, expanded: expanded, copyOnly: copyOnly),
                  let combo = keymap.combo(for: action) else { return nil }
            return KeyHint(action: action, key: combo.display, label: label)
        }
    }

    public static func hintLabel(for action: PanelAction, item: ClipItem, expanded: Bool, copyOnly: Bool) -> String? {
        hintLabel(for: action, row: .clip(item), expanded: expanded, copyOnly: copyOnly)
    }

    /// 提示标签统一两字。nil = 不列：这一行做不了，或是大家都知道 / 不针对这一行的动作（贴回、导航、撤销、设置、关闭）。
    public static func hintLabel(for action: PanelAction, row: PanelRow, expanded: Bool, copyOnly: Bool) -> String? {
        let a = available(for: row)
        switch action {
        case .pasteAsSecret:
            return a.contains(.pasteAsSecret) ? "加密" : nil
        case .pastePlaintext:
            return a.contains(.pastePlaintext) ? (copyOnly ? "复制" : "明文") : nil
        case .markSecret:
            return a.contains(.markSecret) ? "标记" : nil
        case .rename:
            return a.contains(.rename) ? "命名" : nil
        case .toggleExpand:
            guard a.contains(.expand) else { return nil }
            return expanded ? "收起" : (row.clip?.kind == .image ? "预览" : (row.isSecret ? "查看" : "展开"))
        case .openInEditor:
            return a.contains(.openInEditor) ? "打开" : nil
        case .openSource:
            return expanded && a.contains(.openSource) ? "原页" : nil
        case .toggleFavorite:
            guard a.contains(.toggleFavorite) else { return nil }
            // 不随状态变："取消"单独放在提示条里看不出是取消什么；已收藏看行里的 ★，按了有 toast
            return "收藏"
        case .delete:
            return a.contains(.delete) ? "删除" : nil
        case .paste, .undo, .moveUp, .moveDown, .jumpToFirst, .jumpToLast, .openSettings, .close:
            return nil
        }
    }
}
