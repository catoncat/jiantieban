import AppKit

/// 标题原地展开：同一段文字从 1 行往下长到最多 N 行。
/// 量和画用同一套 NSTextFieldCell 配置（按词折行、末行截断），算出的行数就是画出来的行数。
/// 单独成 target 是为了能测：界面 target 是可执行文件，测试 import 不了。
@MainActor
public enum TitleUnfold {
    /// 列表标题字体：1 行和展开时是同一个，展开才像同一段文字往下长
    public static let font = NSFont.systemFont(ofSize: 15, weight: .regular)

    /// 多行时相邻两行的距离（SF 15pt 实测 19pt；1 行标题框更高一点，见 ClipCellView 的 tightLineHeight）
    public static let linePitch: CGFloat = {
        let one = measuredHeight("A", width: 1000)
        return max(1, measuredHeight("A\nA", width: 1000) - one)
    }()

    /// 每个视觉行最多容纳的字符数的保守上界：最窄可见字形（i / l）约 3.5pt，标题最宽约 620pt。
    /// 只用来决定量多少字，截得保守一点不影响结果。
    private static let charsPerLineBound = 250

    /// 让 label 按展开样式画：按词折行，放不下时最后一行结尾加省略号。
    public static func applyMultiline(to label: NSTextField, maxLines: Int) {
        label.cell?.usesSingleLineMode = false
        label.cell?.wraps = true
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = maxLines
    }

    /// 回到 1 行样式（行视图会复用，两种样式来回切）。
    public static func applySingleLine(to label: NSTextField) {
        label.cell?.truncatesLastVisibleLine = false
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
    }

    /// 展开时显示的文字：去掉首尾空白、保留原文换行；只留够 maxLines 行的量（长文不必整段排版），截掉了就补 "…"。
    public static func displayText(_ content: String, maxLines: Int) -> String {
        let text = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = max(1, maxLines) * charsPerLineBound
        var hardLines = 1
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\n" {
                if hardLines == maxLines { return String(text[..<index]) + "…" }
                hardLines += 1
            }
            count += 1
            if count > budget { return String(text[..<index]) + "…" }
            index = text.index(after: index)
        }
        return text
    }

    /// 这段文字在 width 宽的标题框里占几行，封顶 maxLines。
    public static func lineCount(_ text: String, width: CGFloat, maxLines: Int) -> Int {
        let height = measuredHeight(text, width: width)
        let lines = Int(((height - singleLineHeight) / linePitch).rounded()) + 1
        return max(1, min(maxLines, lines))
    }

    /// 列表可见高度放得下的最多行数。
    public static func maxLines(baseHeight: CGFloat, maxHeight: CGFloat) -> Int {
        let extra = ((maxHeight - baseHeight) / linePitch).rounded(.down)
        return max(1, Int(min(extra, 10_000)) + 1) // 上限防 Int 溢出（maxHeight 可能是无穷大）
    }

    /// 展开后的行高：1 行时的行高 + 多出来的行 × 行距；maxLines 为 nil 表示展开全部。不超过 maxHeight（列表可见高度）。
    public static func rowHeight(content: String, maxLines: Int?, titleWidth: CGFloat, baseHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let limit = resolvedMaxLines(maxLines, baseHeight: baseHeight, maxHeight: maxHeight)
        let lines = lineCount(displayText(content, maxLines: limit), width: titleWidth, maxLines: limit)
        return baseHeight + CGFloat(lines - 1) * linePitch
    }

    /// N 行上限和列表高度上限取小的那个。
    public static func resolvedMaxLines(_ maxLines: Int?, baseHeight: CGFloat, maxHeight: CGFloat) -> Int {
        min(maxLines ?? .max, self.maxLines(baseHeight: baseHeight, maxHeight: maxHeight))
    }

    // MARK: - 量

    private static let singleLineHeight = measuredHeight("A", width: 1000)

    private static let measuringCell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = font
        cell.isBordered = false
        cell.isBezeled = false
        cell.usesSingleLineMode = false
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        return cell
    }()

    private static func measuredHeight(_ text: String, width: CGFloat) -> CGFloat {
        measuringCell.stringValue = text
        return measuringCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
    }
}
