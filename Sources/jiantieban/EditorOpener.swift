import AppKit
import Core

/// 编辑器打开（⌘O）。文本：写临时文件后用设置里的编辑器打开；没设（默认）就交给系统默认的 App，
/// 也可用 defaults 指定：defaults write rs.jiantieban editorApp -string "Zed"。
/// 图片：临时副本交给系统默认的看图 App（通常是预览，可标注/裁剪）。
@MainActor
enum EditorOpener {
    /// 密钥行不会走到这里（ItemActions 不给它"打开"）：临时文件里只会有普通文本。
    static func open(_ item: ClipItem) {
        if item.kind == .image {
            // 开临时副本（和文本一样）：在预览里标注/裁剪会自动存盘，不能改到历史里的原图
            guard let path = item.imagePath else { return }
            let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jtb_clip_\(item.id).png")
            try? FileManager.default.removeItem(at: copy)
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
            } catch {
                NSLog("[jtb] open image: copy failed: \(error)")
                return
            }
            NSWorkspace.shared.open(copy)
            return
        }

        let path = NSTemporaryDirectory() + "jtb_clip_\(item.id).txt"
        try? item.content.write(toFile: path, atomically: true, encoding: .utf8)

        let editorApp = AppSettings.shared.editorApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editorApp.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", editorApp, path]
        try? task.run()

        // 聚焦编辑器窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.runningApplications
                .first { $0.localizedName == editorApp }?
                .activate()
        }
    }
}
