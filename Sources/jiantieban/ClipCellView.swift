import AppKit
import Core
import PanelLayout

/// 禁掉「标题截断展开」检测：默认实现每次 layout 都会对被截断的文本做一次完整 CoreText 排版测量
/// （CJK 排版尤其贵），滚动新行入场时是实测主线程热点；返回 .zero 直接跳过测量。
private final class FastLabelCell: NSTextFieldCell {
    override func expansionFrame(withFrame cellFrame: NSRect, in view: NSView) -> NSRect { .zero }
}

/// 玻璃 / vibrancy 会把系统图标抽成灰模，关掉才能露出自带的阴影和彩色。
final class NonVibrantImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}

/// 行内改名输入框：无边框、无焦点环；field editor 默认铺白底，这里拿掉。
private final class InlineNameField: NSTextField {
    override var allowsVibrancy: Bool { false }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            // 量尺截图时隐藏光标：闪烁相位会让两次截图不一致
            editor.insertionPointColor = DebugFlags.solidBackground ? .clear : .labelColor
        }
        return ok
    }
}

/// 单行 NSTextField 的文字贴着 frame 顶部画；要让它和别的元素视觉居中，
/// frame 高度必须等于字体行高（+2pt 内边距），再按中心摆。
extension NSFont {
    var tightLineHeight: CGFloat { ceil(ascender - descender + leading) + 2 }
}

/// 实测（纯白底截图量像素）：NSTextField 画出来的字形框比 frame 中线高约字号的 7%（18pt → 1.25pt，13pt → 0.9pt），
/// 这里按比例把 frame 往下挪，让字形框中线（≈ 大写字高中线，SF Symbols 也按它对齐）落在 midY 上。
func centeredLineFrame(font: NSFont, x: CGFloat, width: CGFloat, midY: CGFloat) -> NSRect {
    let h = font.tightLineHeight
    let nudge = font.pointSize * 0.07
    return NSRect(x: x, y: midY - h / 2 - nudge, width: width, height: h)
}

/// 单行条目，对齐 Spotlight（尺寸见下方常量），右侧 ⌘n 纯文字。
/// 没有副按钮：动作走快捷键和右键，底栏给提示。
/// 展开：普通文本的标题原地往下长（同一段文字、同字体同位置，时间行跟在最下面）；
/// ⌘R 下密钥明文 / 图片大图挂在标题下面。
/// 密钥视图的 jt 记录也用它画：标题是名字，第二行是遮罩；每组第一行上方多一条命名空间标题（不单占一行，
/// ⌘1-9 和选中的行号不受影响）。
final class ClipCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("clipCell")
    // 对照 macOS 26 Spotlight 实测：行 56、图标 36、左边距 28、文字起点 ≈ 80
    static let rowHeight: CGFloat = 56
    static let iconColumn: CGFloat = 36
    static let leading: CGFloat = 28
    static let trailingMargin: CGFloat = 28
    static let textX: CGFloat = leading + iconColumn + 16   // 80：标题起点，搜索文字与之对齐
    private static let bodyMaxHeight: CGFloat = 320
    private static let bodyGap: CGFloat = 6
    private static let bodyBottom: CGFloat = 12
    private static let sourceGap: CGFloat = 6
    private static let sourceHeight: CGFloat = 44
    private static let sourceBottom: CGFloat = 8
    private static var sourceExtra: CGFloat { sourceGap + sourceHeight + sourceBottom }
    /// 组标题条的高度（密钥视图每组第一行）
    static let groupHeaderHeight: CGFloat = 28

    /// 来源只随主动 ⌘R 展开出现，停下后的自动展开不显示。
    private static func showsSource(_ row: PanelRow, _ unfold: RowUnfold?) -> Bool {
        guard row.clip?.browserSource != nil else { return false }
        switch unfold {
        case .all, .body: return true
        case .lines, nil: return false
        }
    }

    // MARK: 高度

    /// maxHeight：列表可见高度，展开的标题不超过它。hasHeader：上方画组标题。
    static func rowHeight(for row: PanelRow, hasHeader: Bool = false, unfold: RowUnfold?, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let header = hasHeader ? groupHeaderHeight : 0
        let extra = showsSource(row, unfold) ? sourceExtra : 0
        switch unfold {
        case nil:
            return header + rowHeight
        case .body(let body):
            return header + rowHeight + bodyGap + bodyHeight(for: body, width: bodyWidth(rowWidth: width)) + bodyBottom + extra
        case .lines, .all:
            // 只有普通文本会原地展开标题
            return header + TitleUnfold.rowHeight(content: row.clip?.content ?? "", maxLines: titleMaxLines(unfold),
                                                  titleWidth: titleWidth(rowWidth: width), baseHeight: rowHeight, maxHeight: maxHeight - extra - header) + extra
        }
    }

    private static func titleMaxLines(_ unfold: RowUnfold?) -> Int? {
        if case .lines(let n) = unfold { return n }
        return nil
    }

    private static func bodyWidth(rowWidth: CGFloat) -> CGFloat {
        max(80, rowWidth - textX - trailingMargin)
    }

    private static let trailingWidth: CGFloat = 30

    /// 标题 / 时间的宽度：文字起点到 ⌘n 提示左边 10pt。行高计算和布局共用。
    private static func titleWidth(rowWidth: CGFloat) -> CGFloat {
        max(40, rowWidth - trailingMargin - trailingWidth - 10 - textX)
    }

    private static func bodyHeight(for body: ExpandedBody, width: CGFloat) -> CGFloat {
        switch body {
        case .text(let text):
            let attr = NSAttributedString(string: text, attributes: [.font: bodyFont])
            let rect = attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
            return min(bodyMaxHeight, ceil(rect.height) + 4)
        case .image(let path):
            guard let size = imagePointSize(path), size.width > 0 else { return 160 }
            let scaled = size.height * min(1, width / size.width)
            return min(bodyMaxHeight, max(48, ceil(scaled)))
        }
    }

    private static var imageSizeCache: [String: NSSize] = [:]
    private static func imagePointSize(_ path: String) -> NSSize? {
        if let cached = imageSizeCache[path] { return cached }
        guard let rep = NSImageRep(contentsOfFile: path) else { return nil }
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        imageSizeCache[path] = size
        return size
    }

    private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    // MARK: 子视图

    private let iconView = NonVibrantImageView()
    private let titleLabel = ClipCellView.makeLabel()
    private let metaLabel = ClipCellView.makeLabel()
    private let trailingLabel = ClipCellView.makeLabel()
    private let nameField = InlineNameField()
    private let bodyLabel = ClipCellView.makeLabel()
    private let bodyImage = NonVibrantImageView()
    private let sourceLabel = ClipCellView.makeLabel()
    private let sourceButton = NSButton(title: "回到页面 ↗", target: nil, action: nil)
    private let groupLabel = ClipCellView.makeLabel()

    private var currentRow: PanelRow?
    private var currentItem: ClipItem? { currentRow?.clip }
    private var currentThumbPath: String?
    private var badge: String?
    private var body: ExpandedBody?
    /// 标题原地展开中（普通文本）：标题框往下长到行高允许的高度
    private var titleUnfolded = false

    /// 行内改名提交（名字已 trim、非空、有变化）。
    var onNameEditCommit: ((RowID, String) -> Void)?
    /// 行内改名结束（提交或取消都会调），面板用它收回焦点。
    var onNameEditEnd: (() -> Void)?
    /// 单击已选中密钥行的标题 → 重命名。
    var onEditName: ((RowID) -> Void)?
    var onOpenSource: ((RowID) -> Void)?

    var isEditingName: Bool { !nameField.isHidden }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    private static let timeCache = NSCache<NSNumber, NSString>()

    static func clearTimeCache() { timeCache.removeAllObjects() }

    /// 用户起过的名字（改名框的初值）；引擎默认名当作没起名。
    private var editableName: String? {
        switch currentRow {
        case .clip(let item): return item.userFacingSecretName
        case .secret(let record): return record.userFacingName
        case nil: return nil
        }
    }

    private static func relativeTime(for item: ClipItem) -> String {
        if let cached = timeCache.object(forKey: NSNumber(value: item.id)) { return cached as String }
        let now = Date()
        let text: String
        if abs(now.timeIntervalSince(item.lastCopiedAt)) < 60 {
            text = "刚刚"
        } else {
            let at = min(item.lastCopiedAt, now)
            text = timeFormatter.localizedString(for: at, relativeTo: now)
        }
        timeCache.setObject(text as NSString, forKey: NSNumber(value: item.id))
        return text
    }

    static func make(in tableView: NSTableView) -> ClipCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipCellView {
            return reused
        }
        let cell = ClipCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: rowHeight))
        cell.identifier = identifier
        return cell
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(frame: .zero)
        label.cell = FastLabelCell(textCell: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func setup() {
        iconView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = TitleUnfold.font
        TitleUnfold.applySingleLine(to: titleLabel)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.cell?.usesSingleLineMode = true
        metaLabel.textColor = .secondaryLabelColor
        addSubview(metaLabel)

        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        trailingLabel.alignment = .right
        trailingLabel.textColor = .tertiaryLabelColor
        addSubview(trailingLabel)

        nameField.isBezeled = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.font = .systemFont(ofSize: 15, weight: .regular)
        nameField.textColor = .labelColor
        nameField.cell?.usesSingleLineMode = true
        nameField.cell?.isScrollable = true
        nameField.cell?.wraps = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 4
        nameField.delegate = self
        nameField.isHidden = true
        nameField.setAccessibilityLabel("密钥名字")
        addSubview(nameField)

        bodyLabel.font = Self.bodyFont
        bodyLabel.textColor = .labelColor
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.usesSingleLineMode = false
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.isSelectable = true
        bodyLabel.isHidden = true
        addSubview(bodyLabel)

        bodyImage.wantsLayer = true
        bodyImage.imageScaling = .scaleProportionallyDown
        bodyImage.imageAlignment = .alignTopLeft
        bodyImage.layer?.cornerRadius = 8
        bodyImage.layer?.cornerCurve = .continuous
        bodyImage.layer?.masksToBounds = true
        bodyImage.isHidden = true
        addSubview(bodyImage)

        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.cell?.usesSingleLineMode = false
        sourceLabel.maximumNumberOfLines = 2
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.isSelectable = true
        sourceLabel.isHidden = true
        addSubview(sourceLabel)

        sourceButton.bezelStyle = .inline
        sourceButton.controlSize = .small
        sourceButton.font = .systemFont(ofSize: 11, weight: .medium)
        sourceButton.target = self
        sourceButton.action = #selector(openSource)
        sourceButton.isHidden = true
        addSubview(sourceButton)

        groupLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        groupLabel.textColor = .secondaryLabelColor
        groupLabel.lineBreakMode = .byTruncatingTail
        groupLabel.cell?.usesSingleLineMode = true
        groupLabel.isHidden = true
        addSubview(groupLabel)
    }

    @objc private func openSource() {
        guard let currentRow else { return }
        onOpenSource?(currentRow.id)
    }

    // MARK: 行内改名

    /// 标题原地变成输入框；回车保存、Esc 取消、失焦保存。面板不消失。
    /// 已有名字：显示原名并全选（直接打字即替换）。没有名字但有推荐：预填 `命名空间/KEY` 并全选（回车接受、打字替换）；
    /// 推荐只有 `命名空间/` 时光标停在末尾，接着打 KEY。
    func beginEditingName(suggestion: String? = nil) {
        guard let currentRow, currentRow.isSecret else { return }
        let existing = editableName
        nameField.stringValue = existing ?? suggestion ?? ""
        nameField.placeholderAttributedString = NSAttributedString(string: "给密钥起个名字，回车保存", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        nameField.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        titleLabel.isHidden = true
        nameField.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(nameField)
        if existing == nil, let suggestion, !SecretNaming.selectsWholeSuggestion(suggestion) {
            let end = (nameField.stringValue as NSString).length
            nameField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        } else {
            nameField.currentEditor()?.selectAll(nil)
        }
    }

    private func endEditingName(commit: Bool) {
        guard isEditingName else { return }
        let value = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nameField.isHidden = true
        titleLabel.isHidden = false
        if commit, let currentRow, !value.isEmpty, value != (editableName ?? "") {
            onNameEditCommit?(currentRow.id, value)
        }
        onNameEditEnd?()
    }

    // MARK: 布局

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshSelectionChrome() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if currentItem?.kind == .image { applyThumbChrome(hasImage: iconView.image != nil) }
    }

    func refreshSelectionChrome() {
        applyTrailing()
        needsLayout = true
    }

    private var isRowSelected: Bool {
        (superview as? NSTableRowView)?.isSelected == true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        // 组标题条在最上面；头部一行始终占 rowHeight，展开的正文挂在下面
        let headerH = groupLabel.isHidden ? 0 : Self.groupHeaderHeight
        let headTop = h - headerH
        let headMidY = headTop - Self.rowHeight / 2
        groupLabel.frame = groupLabel.isHidden ? .zero
            : centeredLineFrame(font: groupLabel.font!, x: Self.leading, width: w - Self.leading - Self.trailingMargin, midY: h - headerH / 2 - 2)

        let icon = Self.iconColumn
        iconView.frame = NSRect(x: Self.leading, y: headMidY - icon / 2, width: icon, height: icon)

        let trailingW = Self.trailingWidth
        let trailingX = w - Self.trailingMargin - trailingW
        trailingLabel.frame = centeredLineFrame(font: trailingLabel.font!, x: trailingX, width: trailingW, midY: headMidY)

        let textX = Self.textX
        let textW = Self.titleWidth(rowWidth: w)
        // 标题 + 时间两行整体居中：两行行高之和 + 2pt 行距
        let titleH = titleLabel.font!.tightLineHeight
        let metaH = metaLabel.font!.tightLineHeight
        let block = titleH + 2 + metaH
        // 两行块只补一半：实测整块补 7% 会低 1.25pt（时间行没有下伸部，块底比行框底高）
        let blockTop = headMidY + block / 2 - titleLabel.font!.pointSize * 0.035 + 0.5
        // 原地展开：第一行不动，标题框往下长出行高多出来的部分（= 多出的行 × 行距），时间行跟着下移
        let sourceExtra = sourceLabel.isHidden ? 0 : Self.sourceExtra
        let unfoldH = titleUnfolded ? max(0, headTop - Self.rowHeight - sourceExtra) : 0
        titleLabel.frame = NSRect(x: textX, y: blockTop - titleH - unfoldH, width: textW, height: titleH + unfoldH)
        metaLabel.frame = NSRect(x: textX, y: blockTop - titleH - unfoldH - 2 - metaH, width: textW, height: metaH)
        // 改名框覆盖标题行，同高同位，左右各让 3pt 给淡底
        nameField.frame = nameField.isHidden ? .zero : titleLabel.frame.insetBy(dx: -3, dy: -1)

        if sourceLabel.isHidden {
            sourceLabel.frame = .zero
            sourceButton.frame = .zero
        } else {
            let buttonWidth: CGFloat = 104
            let sourceW = Self.bodyWidth(rowWidth: w)
            sourceLabel.frame = NSRect(x: textX, y: Self.sourceBottom, width: sourceW - buttonWidth - Self.sourceGap, height: Self.sourceHeight)
            sourceButton.frame = NSRect(x: textX + sourceW - buttonWidth, y: Self.sourceBottom + (Self.sourceHeight - 24) / 2, width: buttonWidth, height: 24)
        }

        guard let body else {
            bodyLabel.frame = .zero
            bodyImage.frame = .zero
            return
        }
        let bodyW = Self.bodyWidth(rowWidth: w)
        let bodyH = max(0, headTop - Self.rowHeight - Self.bodyGap - Self.bodyBottom - sourceExtra)
        let bodyRect = NSRect(x: textX, y: Self.bodyBottom + sourceExtra, width: bodyW, height: bodyH)
        switch body {
        case .text:
            bodyLabel.frame = bodyRect
            bodyImage.frame = .zero
        case .image:
            bodyImage.frame = bodyRect
            bodyLabel.frame = .zero
        }
    }

    // MARK: 配置

    /// badge 为 "⌘1"…"⌘9" 或 nil；unfold 非 nil 即展开态。maxHeight：列表可见高度（⌘R 展开全部时封顶）。
    /// header：密钥视图里每组第一行上方的命名空间标题。
    func configure(with row: PanelRow, header: String? = nil, badge: String?, unfold: RowUnfold?, maxHeight: CGFloat) {
        self.badge = badge
        if case .body(let body) = unfold { self.body = body } else { self.body = nil }
        currentRow = row
        currentThumbPath = nil
        nameField.isHidden = true
        titleLabel.isHidden = false
        renameClickTask?.cancel()
        renameClickTask = nil
        groupLabel.stringValue = header ?? ""
        groupLabel.isHidden = header == nil

        switch row {
        case .clip(let item):
            configureClip(item, unfold: unfold, maxHeight: maxHeight)
        case .secret(let record):
            titleUnfolded = false
            TitleUnfold.applySingleLine(to: titleLabel)
            titleLabel.stringValue = record.displayTitle
            metaLabel.stringValue = record.displayPreview
            setGlyph(ClipIcons.symbol("lock.fill"), tint: .controlAccentColor)
            sourceLabel.isHidden = true
            sourceButton.isHidden = true
            setAccessibilityLabel("\(record.name)，密钥引用 \(record.reference)")
        }

        bodyLabel.isHidden = true
        bodyImage.isHidden = true
        bodyImage.image = nil
        if let body {
            switch body {
            case .text(let text):
                bodyLabel.stringValue = text
                bodyLabel.isHidden = false
            case .image(let path):
                bodyImage.image = NSImage(contentsOfFile: path)
                bodyImage.isHidden = false
            }
        }

        applyTrailing()
        needsLayout = true
    }

    private func configureClip(_ item: ClipItem, unfold: RowUnfold?, maxHeight: CGFloat) {
        switch unfold {
        case .lines, .all:
            // 同一段文字，只是保留换行、放开行数；截到放得下的量，结尾省略号由 label 画
            let maxLines = TitleUnfold.resolvedMaxLines(Self.titleMaxLines(unfold), baseHeight: Self.rowHeight, maxHeight: maxHeight)
            titleUnfolded = true
            TitleUnfold.applyMultiline(to: titleLabel, maxLines: maxLines)
            titleLabel.stringValue = TitleUnfold.displayText(item.content, maxLines: maxLines)
        case nil, .body:
            titleUnfolded = false
            TitleUnfold.applySingleLine(to: titleLabel)
            titleLabel.stringValue = item.displayTitle
        }
        metaLabel.stringValue = (item.isFavorite ? "★ " : "") + (item.secretMissing ? "密钥已删除 · " : "") + Self.relativeTime(for: item)

        switch item.kind {
        case .text:
            // 字形表类别，颜色表性质：整列单色，只有密钥的锁带强调色
            setGlyph(ClipIcons.icon(for: item), tint: item.isSecret && !item.secretMissing ? .controlAccentColor : .secondaryLabelColor)
        case .image:
            applyThumb(imagePath: item.imagePath, thumbPath: item.thumbPath)
        }

        if Self.showsSource(.clip(item), unfold), let source = item.browserSource {
            let app = source.bundleID == "net.imput.helium" ? "Helium" : "Chrome"
            sourceLabel.stringValue = "可能来自 \(app) · \(source.title)\n\(source.url)"
            sourceLabel.toolTip = source.url
            sourceLabel.isHidden = false
            sourceButton.isHidden = false
        } else {
            sourceLabel.isHidden = true
            sourceButton.isHidden = true
        }
        applyAccessibility(for: item)
    }

    func setBadge(_ badge: String?) {
        self.badge = badge
        applyTrailing()
    }

    private var renameClickTask: DispatchWorkItem?

    /// Finder 同款：已选中的密钥行，再单击标题 = 重命名；双击仍是贴回，所以等一个双击间隔再触发。
    override func mouseDown(with event: NSEvent) {
        renameClickTask?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let wasSelected = isRowSelected
        let onTitle = titleLabel.frame.insetBy(dx: -2, dy: -4).contains(point)
        super.mouseDown(with: event)
        guard event.clickCount == 1, wasSelected, onTitle,
              let currentRow, ItemActions.available(for: currentRow).contains(.rename), !isEditingName else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, let row = self.currentRow, row.id == currentRow.id, self.isRowSelected else { return }
            self.onEditName?(row.id)
        }
        renameClickTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: task)
    }

    private func setGlyph(_ image: NSImage, tint: NSColor) {
        iconView.layer?.cornerRadius = 0
        iconView.layer?.masksToBounds = false
        iconView.layer?.borderWidth = 0
        iconView.layer?.backgroundColor = nil
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = tint
        iconView.image = image
    }

    private func applyThumb(imagePath: String?, thumbPath: String?) {
        let path = thumbPath ?? imagePath
        currentThumbPath = path
        guard let path else {
            showThumb(nil)
            return
        }
        if let img = ThumbnailCache.shared.preview(for: path, completion: { [weak self] decoded in
            MainActor.assumeIsolated {
                guard let self, self.currentThumbPath == path else { return }
                self.showThumb(decoded)
            }
        }) {
            showThumb(img)
        } else {
            showThumb(nil)
        }
    }

    private func showThumb(_ img: NSImage?) {
        iconView.imageScaling = .scaleAxesIndependently
        iconView.contentTintColor = nil
        iconView.image = img
        applyThumbChrome(hasImage: img != nil)
    }

    private func applyThumbChrome(hasImage: Bool) {
        iconView.layer?.cornerRadius = 8
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconView.layer?.borderWidth = 1
            iconView.layer?.borderColor = NSColor.separatorColor.cgColor
            iconView.layer?.backgroundColor = hasImage ? nil : NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    /// 快捷键提示：纯文字、等宽数字；选中行 secondary，其他三级灰。
    private func applyTrailing() {
        guard let badge, !badge.isEmpty else {
            trailingLabel.stringValue = ""
            return
        }
        trailingLabel.stringValue = badge
        trailingLabel.textColor = isRowSelected ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func applyAccessibility(for item: ClipItem) {
        if item.isSecret, let token = item.secretToken, !token.isEmpty {
            setAccessibilityLabel("\(item.displayTitle)，密钥引用 \(token)")
        } else {
            setAccessibilityLabel(nil)
        }
    }
}

// MARK: - NSTextFieldDelegate（行内改名）

extension ClipCellView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endEditingName(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditingName(commit: false)
            return true
        }
        return false
    }

    /// 点到别处失焦：视为保存，别把已经打的字丢掉。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        endEditingName(commit: true)
    }
}
