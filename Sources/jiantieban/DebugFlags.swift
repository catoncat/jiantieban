import AppKit

/// 截图量尺 / 验收用的隐藏开关，全部集中在这里。
/// 环境变量只在 `_debug-panel` / `_debug-scroll` 启动时生效，真实使用中即使 env 里残留也不会改变行为。
enum DebugFlags {
    private static let env = ProcessInfo.processInfo.environment
    private static let args = CommandLine.arguments

    /// 启动后立刻显示面板，失焦不自动关（screencapture 会抢 key window）
    static let showPanelOnLaunch = args.contains("_debug-panel") || args.contains("_debug-scroll")
    /// 显示后 60Hz 连续下移选择，复现快速导航滚动问题 + sample 采样
    static let autoScroll = args.contains("_debug-scroll")

    /// 纯色底替代玻璃（浅色白 / 暗色黑），并隐藏光标：截图可逐像素比对
    static let solidBackground = flag("JIANTIEBAN_DEBUG_SOLID")
    /// 假装一直按住 ⌘：显示角标与快捷键提示
    static let holdCommand = flag("JIANTIEBAN_DEBUG_CMD")
    /// 打开即切到「图片」筛选
    static let imageFilter = flag("JIANTIEBAN_DEBUG_FILTER")
    /// 面板强制外观：`light` / `dark`；不设则跟随系统
    static let appearance: NSAppearance.Name? = {
        guard showPanelOnLaunch else { return nil }
        switch env["JIANTIEBAN_DEBUG_APPEARANCE"] {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }()
    /// 打开后展开当前选中行
    static let expandSelected = flag("JIANTIEBAN_DEBUG_EXPAND")
    /// 打开即在搜索框里输入这段文字
    static let query: String? = showPanelOnLaunch ? env["JIANTIEBAN_DEBUG_QUERY"] : nil
    /// 打开后按顺序回放的按键，逗号分隔：up / down / cmd-up / cmd-down / cmd-r / cmd-l / cmd-e / cmd-d / cmd-s / cmd-o / cmd-z /
    /// type:文字（输入到当前输入框）/ field-enter（在改名框里回车）。不含会贴回的回车。
    static let keys: [String] = showPanelOnLaunch
        ? (env["JIANTIEBAN_DEBUG_KEYS"]?.split(separator: ",").map(String.init) ?? [])
        : []

    private static func flag(_ name: String) -> Bool {
        showPanelOnLaunch && env[name] != nil
    }
}
