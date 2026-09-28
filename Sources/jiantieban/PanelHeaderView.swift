import AppKit
import Core

// 面板顶栏：放大镜 + 搜索框 + 右侧筛选标签 / ⌘ 快捷键提示条。从 PanelController.swift 原样搬出。

/// 面板里所有"圆角块 + 文字"的小元件（快捷键 keycap、筛选标签）都走这一个 view 自绘，
/// 垂直位置只有一个算法：行框（ascender − descender）中线 = 视图中线。不用 NSTextField，避免第二套度量。
private final class HintStripView: NSView {
    /// 一组 = 键帽 + 标签（筛选标签只有键帽）。priority：放不下时数值小的先去掉。
    struct Group {
        let key: String
        let label: String?
        let priority: Int
    }

    private var groups: [Group] = []
    /// 可用宽度。放不下时去掉最不要紧的一组，不画半截字
    var maxWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if maxWidth != oldValue { needsDisplay = true } }
    }
    private let capFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let capH: CGFloat = 18
    private static let capPadX: CGFloat = 6
    private static let capToLabel: CGFloat = 6
    /// 组间距固定 24（用户要组与组之间松一点）。不随宽度收紧：换一行、组数一变间距就跳，看着乱
    private static let groupGap: CGFloat = 24

    override var allowsVibrancy: Bool { false }

    func setGroups(_ groups: [Group]) {
        self.groups = groups
        needsDisplay = true
    }

    private func capWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: capFont]).size().width) + Self.capPadX * 2
    }

    private func labelWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: labelFont]).size().width)
    }

    private func width(of group: Group) -> CGFloat {
        capWidth(group.key) + (group.label.map { Self.capToLabel + labelWidth($0) } ?? 0)
    }

    private func totalWidth(_ groups: [Group], gap: CGFloat) -> CGFloat {
        groups.reduce(0) { $0 + width(of: $1) } + gap * CGFloat(max(0, groups.count - 1))
    }

    /// 放得下的组：超出 maxWidth 时去掉 priority 最小的一组（同分去后面的），直到放得下
    private var fitted: [Group] {
        var shown = groups
        while !shown.isEmpty, totalWidth(shown, gap: Self.groupGap) > maxWidth,
              let i = shown.indices.min(by: { (shown[$0].priority, -$0) < (shown[$1].priority, -$1) }) {
            shown.remove(at: i)
        }
        return shown
    }

    var preferredWidth: CGFloat { totalWidth(fitted, gap: Self.groupGap) }

    override func draw(_ dirtyRect: NSRect) {
        let groups = fitted
        let gap = Self.groupGap
        guard !groups.isEmpty else { return }
        let midY = bounds.midY
        var x: CGFloat = max(0, bounds.width - totalWidth(groups, gap: gap))
        let capAttrs: [NSAttributedString.Key: Any] = [.font: capFont, .foregroundColor: NSColor.secondaryLabelColor]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        for group in groups {
            let capW = capWidth(group.key)
            let cap = NSRect(x: x, y: midY - Self.capH / 2, width: capW, height: Self.capH)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5).fill()
            // draw(at:) 原点是行框底部；行框中线放到 midY
            NSAttributedString(string: group.key, attributes: capAttrs)
                .draw(at: NSPoint(x: cap.minX + Self.capPadX, y: midY - (capFont.ascender - capFont.descender) / 2))
            x += capW
            if let label = group.label {
                x += Self.capToLabel
                NSAttributedString(string: label, attributes: labelAttrs)
                    .draw(at: NSPoint(x: x, y: midY - (labelFont.ascender - labelFont.descender) / 2))
                x += labelWidth(label)
            }
            x += gap
        }
    }
}

/// 顶栏：放大镜 + 搜索字段；只有筛选生效时右侧出现一个小标签（"密钥"/"图片"…），"全部"时什么都没有。
final class SpotlightHeaderView: NSView {
    private let chrome = SearchFieldChrome()
    private let filterTag = HintStripView()
    private let hints = HintStripView()
    private weak var field: NSTextField?

    func setHints(_ hints: [(key: String, label: String, priority: Int)]) {
        self.hints.setGroups(hints.map { .init(key: $0.key, label: $0.label, priority: $0.priority) })
        self.hints.isHidden = hints.isEmpty
        needsLayout = true
    }

    func embed(_ field: SpotlightSearchField) {
        self.field = field
        chrome.embed(field)
        addSubview(chrome)

        filterTag.isHidden = true
        addSubview(filterTag)
        hints.isHidden = true
        addSubview(hints)
    }

    func setChip(_ chip: SearchTypeChip) {
        if chip == .all {
            filterTag.isHidden = true
        } else {
            filterTag.setGroups([.init(key: chip.title, label: nil, priority: 0)])
            filterTag.isHidden = false
        }
        needsLayout = true
    }

    func syncSearchChrome() {
        chrome.refresh()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        let fieldH = SearchFieldChrome.height
        let fieldX: CGFloat = ClipCellView.leading
        var right = bounds.width - ClipCellView.trailingMargin
        // 按住 ⌘：顶栏整条是快捷键提示（这时不在打字），放大镜换成 ⌘，提示从标题那一列开始。
        // 搜索文字和筛选标签只是看不见：焦点和内容都在，⌘V / ⌘A 照常作用在搜索框上，松开 ⌘ 原样回来。
        let commandMode = !hints.isHidden
        chrome.setCommandMode(commandMode)
        filterTag.alphaValue = commandMode ? 0 : 1
        if commandMode {
            let x = ClipCellView.textX
            hints.maxWidth = max(0, right - x)
            hints.frame = NSRect(x: x, y: 0, width: hints.preferredWidth, height: bounds.height)
        }
        if !filterTag.isHidden {
            let tagW = filterTag.preferredWidth
            filterTag.frame = NSRect(x: right - tagW, y: 0, width: tagW, height: bounds.height)
            right -= tagW + 16
        }
        // 两种模式下搜索框尺寸不变：松开 ⌘ 时文字不重排
        chrome.frame = NSRect(
            x: fieldX,
            y: (bounds.height - fieldH) / 2,
            width: max(80, right - fieldX),
            height: fieldH
        )
    }
}

/// 28pt 圆角填充搜索框：放大镜 + 字段 + 清除。不用 NSGlassEffectView（interactive glass 要 macOS 27+）。
private final class SearchFieldChrome: NSView {
    static let height: CGFloat = 34
    private static let cornerRadius: CGFloat = 0
    private static let icon: CGFloat = 18
    private static let pad: CGFloat = 4

    private let magnifier = NonVibrantImageView()
    private let clearButton = SearchClearButton()
    private weak var field: SpotlightSearchField?
    private var focused = false
    private var commandMode = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        magnifier.imageScaling = .scaleProportionallyDown
        magnifier.image = Self.symbol(named: "magnifyingglass", pointSize: 19, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor
        magnifier.setAccessibilityElement(false)
        addSubview(magnifier)

        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.imagePosition = .imageOnly
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.image = Self.symbol(named: "xmark.circle.fill", pointSize: 12, weight: .regular)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.focusRingType = .none
        clearButton.setAccessibilityLabel("清除")
        clearButton.setAccessibilityRole(.button)
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.isHidden = true
        addSubview(clearButton)

        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    func embed(_ field: SpotlightSearchField) {
        self.field = field
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(string: "搜索剪贴板历史", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.refusesFirstResponder = false
        field.setAccessibilityRole(.textField)
        field.setAccessibilityLabel("搜索剪贴板历史")
        field.onFocusChange = { [weak self] focused in
            self?.setFocused(focused)
        }
        addSubview(field)
        refresh()
    }

    func refresh() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// 按住 ⌘：放大镜换成 ⌘ 符号；搜索文字、占位符、清除按钮只是看不见（仍是第一响应者）。
    func setCommandMode(_ on: Bool) {
        guard on != commandMode else { return }
        commandMode = on
        magnifier.image = on
            ? Self.symbol(named: "command", pointSize: 16, weight: .medium)
            : Self.symbol(named: "magnifyingglass", pointSize: 19, weight: .medium)
        field?.alphaValue = on ? 0 : 1
        clearButton.alphaValue = on ? 0 : 1
    }

    func setFocused(_ focused: Bool) {
        self.focused = focused
        applyFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
        magnifier.contentTintColor = .tertiaryLabelColor
        clearButton.contentTintColor = .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let mag = Self.icon
        // 放大镜中心落在图标列中轴（行内图标 x=16 宽 32 → 中心 32；chrome 自身从 16 起）
        // 实测符号图在 image view 里偏低 0.75pt（符号自带基线留白），往上抬 0.75
        magnifier.frame = NSRect(x: ClipCellView.iconColumn / 2 - mag / 2, y: (h - mag) / 2 + 0.75, width: mag, height: mag)

        let hasText = !(field?.stringValue.isEmpty ?? true)
        clearButton.isHidden = !hasText
        clearButton.setAccessibilityHidden(!hasText)
        let clearSide: CGFloat = 22
        let trailing = hasText ? bounds.width - Self.pad - clearSide : bounds.width - Self.pad
        if hasText {
            clearButton.frame = NSRect(
                x: bounds.width - Self.pad - clearSide,
                y: (h - clearSide) / 2,
                width: clearSide,
                height: clearSide
            )
        }

        // 搜索文字起点与行标题起点同一条线，扣掉 field 自身 2pt 内边距；高度 = 字体行高，按中心摆。
        // 对齐到像素：分数坐标下 field editor 的文字位置随布局时机差半点（按住 ⌘ 打开、提示条出现时会抖）
        let fieldX = ClipCellView.textX - ClipCellView.leading - 2
        if let field {
            let frame = centeredLineFrame(font: field.font!, x: fieldX, width: max(40, trailing - 4 - fieldX), midY: h / 2)
            field.frame = backingAlignedRect(frame, options: .alignAllEdgesNearest)
        }
    }

    @objc private func clearSearch() {
        guard let field else { return }
        field.stringValue = ""
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = ""
        }
        refresh()
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        window?.makeFirstResponder(field)
    }

    /// Spotlight 同款：搜索区不画盒子，放大镜 + 大字直接落在玻璃上，靠下方发丝线分隔。
    private func applyFill() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        magnifier.contentTintColor = focused ? .labelColor : .secondaryLabelColor
    }

    private static func symbol(named name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let configured = base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
        )
        configured?.isTemplate = true
        return configured
    }
}

private final class SearchClearButton: NSButton {
    override var allowsVibrancy: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

/// 搜索框：系统 field editor 默认会铺一层白底，盖住圆角填充，这里强制拿掉。
final class SpotlightSearchField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override var allowsVibrancy: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            // 量尺截图时隐藏光标：闪烁相位会让两次截图不一致
            editor.insertionPointColor = DebugFlags.solidBackground ? .clear : .labelColor
        }
        if ok { onFocusChange?(true) }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
