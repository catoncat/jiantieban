import AppKit

/// 面板里所有动画时长的唯一出处（依据 Apple HIG · Motion）：
/// - 高频操作不加动画：↑↓ 移动、打字、切分类、按住 ⌘ 出提示、面板出现 / 收起
///   （"avoid adding motion to UI interactions that occur frequently"）。
/// - 一次性的变化给短动画、减速收尾：停下后展开、⌘R、删除 / 撤销、toast（"brevity and precision"）。
/// - 动画不挡按键：动画中再按键，直接跳到新状态（"Let people cancel motion"）。
/// - 系统"减少动态效果"打开时全部为 0（"Make motion optional"）。
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 行高变化：停下展开、⌘R 展开 / 收起
    static var rowResize: TimeInterval { reduced ? 0 : 0.15 }
    /// 删除淡出、撤销淡入
    static var rowFade: NSTableView.AnimationOptions { reduced ? [] : .effectFade }
    static var toastIn: TimeInterval { reduced ? 0 : 0.12 }
    static var toastOut: TimeInterval { reduced ? 0 : 0.2 }

    /// duration 为 0 时不起动画组：变化立即生效，也打断正在进行的同类动画。
    static func run(_ duration: TimeInterval, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = duration > 0
            changes()
        }
    }
}
