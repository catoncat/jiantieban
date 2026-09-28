import AppKit
import Combine
import SwiftUI

/// 首启引导页：欢迎 → 权限说明。
/// 避免使用 `@State`（CLT 环境 SwiftUI macro 插件不可用），页面切换由 ObservableObject 驱动。
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage = .welcome
    @Published var accessibilityTrusted = false
    @Published var didRequestAccessibility = false
}

enum OnboardingPage {
    case welcome
    case permission
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onStart: () -> Void
    var onOpenSettings: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch model.page {
            case .welcome:
                welcomeContent
            case .permission:
                permissionContent
            }
        }
        .frame(width: 480, height: 320)
        .padding(24)
    }

    private var welcomeContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("你的剪贴板，终于有了记忆")
                .font(.title2.bold())
            Text("jiantieban 在后台默默记下你复制过的每一段文字和图片，随时 ⇧⌘V 调出、秒搜、一键贴回。常驻内存仅约 20–30MB，几乎不占资源。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                Label("自动记录：复制即存，无需操作", systemImage: "arrow.down.doc")
                Label("瞬时搜索：10 万条也能毫秒级命中", systemImage: "magnifyingglass")
                Label("一键贴回：⌘1–9 直接贴回视口前 9 条", systemImage: "keyboard")
            }
            .font(.callout)
            .padding(.vertical, 4)
            Button("开始使用", action: onStart)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private var permissionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "cursorarrow.click.badge.clock")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("启用一键贴回")
                .font(.title2.bold())
            Text("jiantieban 需要“辅助功能”权限，才能把选中的内容自动贴到当前 App。权限只用于你主动执行贴回时模拟一次 ⌘V。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(permissionStatusText)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            HStack {
                Button(model.accessibilityTrusted ? "完成" : "先用仅复制模式", action: onLater)
                if !model.accessibilityTrusted {
                    Button(model.didRequestAccessibility ? "重新打开系统设置" : "启用一键贴回", action: onOpenSettings)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
    }

    private var permissionStatusText: String {
        if model.accessibilityTrusted {
            return "辅助功能已开启，现在可以一键贴回。"
        }
        if model.didRequestAccessibility {
            return "尚未获得权限，当前使用仅复制模式；你可以稍后重试。"
        }
        return "不授权也可以正常记录、搜索和复制历史内容。"
    }
}
