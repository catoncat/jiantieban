import AppKit
import PanelLayout

/// 原地展开的行高：量出来的行数决定面板怎么长，算错了要么截掉要看的字，要么留一截空白。
/// 用真的 AppKit 排版量（和 label 画的是同一套配置），不是假的测量器。
@MainActor
enum PanelLayoutTests {
    static let all: [TestCase] = [
        TestCase("停下展开：多行文本高度 = N 行对应的高度；1 行放得下的不变高", testLinesCap),
        TestCase("按宽度折行也算行数：窄了行多，但不超过 N", testWrapCountsLines),
        TestCase("展开全部：不超过传入的列表高度上限，且正好是放得下的整行数", testListHeightCap),
        TestCase("显示文字只截到 N 行，截掉了补省略号", testDisplayTextCut),
    ]

    private static let base: CGFloat = 56
    private static let pitch = TitleUnfold.linePitch

    private static func lines(_ n: Int) -> String {
        (1...n).map { "line \($0)" }.joined(separator: "\n")
    }

    static func testLinesCap() throws {
        try expect(pitch > 10 && pitch < 30, "line pitch looks wrong: \(pitch)")
        let h = TitleUnfold.rowHeight(content: lines(10), maxLines: 4, titleWidth: 400, baseHeight: base, maxHeight: 1000)
        try expectEqual(h, base + 3 * pitch, "10 lines capped at 4")
        let two = TitleUnfold.rowHeight(content: lines(2), maxLines: 4, titleWidth: 400, baseHeight: base, maxHeight: 1000)
        try expectEqual(two, base + pitch, "2 lines stay 2")
        let short = TitleUnfold.rowHeight(content: "  hello world \n", maxLines: 4, titleWidth: 400, baseHeight: base, maxHeight: 1000)
        try expectEqual(short, base, "fits on one line: no growth (trailing newline trimmed)")
    }

    static func testWrapCountsLines() throws {
        let text = String(repeating: "中文排版 wrap test ", count: 6) // 没有换行符，只靠折行
        let wide = TitleUnfold.rowHeight(content: text, maxLines: 4, titleWidth: 2000, baseHeight: base, maxHeight: 1000)
        let narrow = TitleUnfold.rowHeight(content: text, maxLines: 4, titleWidth: 200, baseHeight: base, maxHeight: 1000)
        let medium = TitleUnfold.rowHeight(content: text, maxLines: 4, titleWidth: 500, baseHeight: base, maxHeight: 1000)
        try expectEqual(wide, base, "one line at 2000pt")
        try expectEqual(narrow, base + 3 * pitch, "capped at 4 lines when narrow")
        try expect(medium > base && medium < narrow, "medium width wraps to 2-3 lines: \(medium)")
    }

    static func testListHeightCap() throws {
        let cap: CGFloat = 150
        let h = TitleUnfold.rowHeight(content: lines(40), maxLines: nil, titleWidth: 400, baseHeight: base, maxHeight: cap)
        try expect(h <= cap, "\(h) exceeds cap \(cap)")
        try expectEqual(h, base + ((cap - base) / pitch).rounded(.down) * pitch)
        let n = TitleUnfold.rowHeight(content: lines(40), maxLines: 4, titleWidth: 400, baseHeight: base, maxHeight: base + pitch)
        try expectEqual(n, base + pitch, "N lines also obey the list height")
        let full = TitleUnfold.rowHeight(content: lines(5), maxLines: nil, titleWidth: 400, baseHeight: base, maxHeight: 1000)
        try expectEqual(full, base + 4 * pitch, "all lines when they fit")
    }

    static func testDisplayTextCut() throws {
        try expectEqual(TitleUnfold.displayText(lines(6), maxLines: 4), lines(4) + "…")
        try expectEqual(TitleUnfold.displayText("\n  a\r\nb  \n", maxLines: 4), "a\nb")
        let long = String(repeating: "x", count: 100_000)
        try expect(TitleUnfold.displayText(long, maxLines: 4).count < 2000, "long text is cut before layout")
    }
}
