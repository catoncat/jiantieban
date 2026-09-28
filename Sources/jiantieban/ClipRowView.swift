import AppKit

/// 选中行：半透明强调色，玻璃能透出来。不用 NSVisualEffectView（会盖住 NSGlassEffectView）。
final class ClipRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var isOpaque: Bool { false }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// 行顶上的组标题条（密钥视图每组第一行）：选中底色不盖住它
    var headerInset: CGFloat = 0 {
        didSet { if headerInset != oldValue { needsDisplay = true } }
    }

    static let identifier = NSUserInterfaceItemIdentifier("clipRow")

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            for case let cell as ClipCellView in subviews {
                cell.refreshSelectionChrome()
            }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // 玻璃上要保持透明，否则行会盖住 Liquid Glass。
    }

    override func drawSelection(in dirtyRect: NSRect) {
        var content = bounds
        content.size.height -= headerInset
        if isFlipped { content.origin.y += headerInset }
        let rect = content.insetBy(dx: 12, dy: 0)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        // 非强调选中（HIG）：玻璃已经偏白，白色叠上去看不见，用中性深色 10%；暗色用白 12%
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.10)).setFill()
            path.fill()
        }
    }
}
