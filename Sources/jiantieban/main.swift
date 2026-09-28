import Core
import Foundation
import PastebackPlatform

func dataDir() -> URL {
    if let override = ProcessInfo.processInfo.environment["JIANTIEBAN_HOME"] {
        return URL(fileURLWithPath: override)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("jiantieban")
}

@MainActor
func makeEngine() throws -> (ClipStore, IngestPipeline, SecretManager) {
    let dir = dataDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let settings = AppSettings.shared
    let config = StoreConfig(
        retentionSeconds: settings.retentionSeconds,
        hardLimit: settings.hardLimit,
        maxSaveLength: settings.maxSaveLength,
        favoritesPermanent: settings.favoritesPermanent
    )
    let store = try ClipStore(path: dir.appendingPathComponent("jiantieban.db").path, config: config)
    let imageStore = try ImageStore(directory: dir.appendingPathComponent("images"))
    let secrets = SecretManager(store: store)
    let pipeline = IngestPipeline(store: store, imageStore: imageStore)
    pipeline.ocrLanguages = settings.ocrLanguages
    return (store, pipeline, secrets)
}

/// 参数错误：提示 + 退出码 2。以前是 fatalError——进程崩溃、留崩溃报告，调用方（agent）只看到一串栈。
func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("jiantieban: \(message)\n运行 jiantieban help 查看用法\n".utf8))
    exit(2)
}

func printPage(_ page: SearchPage) {
    print("total=\(page.total) page=\(page.page)/\(page.pageSize)")
    for item in page.items {
        let fav = item.isFavorite ? "★" : " "
        let time = item.lastCopiedAt.formatted(.dateTime.hour().minute().second())
        switch item.kind {
        case .text:
            let preview: String
            if item.isSecret {
                let name = item.secretName ?? "未命名密钥"
                preview = "🔒 \(name) \(item.maskedPreview ?? "")"
            } else {
                preview = item.content.replacingOccurrences(of: "\n", with: "⏎")
            }
            print("\(fav) [\(item.id)] \(time) \(preview.prefix(80))")
        case .image:
            let ocr = item.ocrText.map { " ocr=\($0.prefix(40))" } ?? ""
            print("\(fav) [\(item.id)] \(time) [图片] \(item.imagePath ?? "")\(ocr)")
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || DebugFlags.showPanelOnLaunch {
    // 无参数 → App 模式（.app 双击 / 开机自启走这里）
    MainActor.assumeIsolated { runApp() }
}
guard let command = args.first, command != "help" else {
    print("""
    usage: jiantieban <command>
      watch                 监听剪贴板（M1 CLI 模式，Ctrl+C 退出）
      list [page]           最近历史
      search <query>        搜索（支持 :img / :text / :fav / :secret 前缀）
      add-text <text>       手动写入一条文本（测试用）
      add-image <png>       手动写入一条图片（测试用）
      delete <id>           删除条目
      fav <id>              切换收藏
      mark-secret <id> [name]      把某条文本标记为密钥（真值交给 jt，记录只留引用）
      bench <n>             插入 n 条合成数据并测量检索耗时
      stats                 统计信息
      clear                 清空历史
      version               显示版本号

    密钥的列出 / 改名 / 解析用 jt：jt ls、jt mv、jt resolve <引用或名称> [--env NAME] --exec <命令…>

    退出码：0 成功，1 执行出错（如 jt 不可用），2 参数错误或命令已移到 jt
    """)
    exit(0)
}

@MainActor
func run() throws {
let (store, pipeline, secrets) = try makeEngine()

switch command {
case "watch":
    let monitor = ClipboardMonitor(pasteboard: SystemPasteboard()) { snapshot in
        pipeline.handle(snapshot)
    }
    monitor.start()
    print("watching clipboard (0.8s interval), Ctrl+C to stop")
    RunLoop.main.run()

case "list":
    let page = args.count > 1 ? Int(args[1]) ?? 1 : 1
    printPage(try store.search(SearchQuery(), page: page))

case "search":
    guard args.count > 1 else { usageError("search needs a query") }
    let query = SearchQuery(parsing: args.dropFirst().joined(separator: " "))
    printPage(try store.search(query))

case "add-text":
    guard args.count > 1 else { usageError("add-text needs content") }
    let (item, inserted) = try store.upsertText(args.dropFirst().joined(separator: " "))
    print("\(inserted ? "inserted" : "deduped") id=\(item.id)")

case "add-image":
    // 测试/量尺用：从 PNG 文件写入一条图片
    guard args.count > 1, let png = FileManager.default.contents(atPath: args[1]) else { usageError("add-image needs a PNG path") }
    let imageStore = try ImageStore(directory: dataDir().appendingPathComponent("images"))
    let saved = try imageStore.save(pngData: png)
    let (img, insertedImg) = try store.upsertImage(imagePath: saved.imagePath, thumbPath: saved.thumbPath, hash: saved.hash)
    print("\(insertedImg ? "inserted" : "deduped") id=\(img.id)")

case "delete":
    guard args.count > 1, let id = Int64(args[1]) else { usageError("delete needs an id") }
    if let removed = try store.delete(id: id) {
        ImageStore.removeFiles([removed.imagePath, removed.thumbPath].compactMap { $0 })
        print("deleted \(id)")
    } else {
        print("not found: \(id)")
    }

case "fav":
    guard args.count > 1, let id = Int64(args[1]) else { usageError("fav needs an id") }
    print("favorite=\(try store.toggleFavorite(id: id))")

case "mark-secret":
    guard args.count > 1, let id = Int64(args[1]) else { usageError("mark-secret needs an id") }
    let name = args.count > 2 ? args[2] : nil
    let item = try secrets.markAsSecret(id: id, name: name)
    print("marked \(item.id) token=\(item.secretToken ?? "")")

case "unmark-secret":
    // ADR-0001：没有"取消密钥"。给记着旧用法的调用方（agent）一句去向，而不是 unknown command
    usageError("unmark-secret 已移除：面板里标记后可 ⌘Z 撤销；不再需要的密钥在密钥视图删除，或 jt rm <引用>")

case "secrets", "annotate", "resolve":
    // ADR-0001 / 06：与 jt 重复的密钥命令收敛到 jt（两套默认值不同，Agent 曾因此读到空变量）。
    // 给记着旧用法的调用方一句去向，而不是 unknown command
    let moved = ["secrets": "jt ls", "annotate": "jt mv <引用或名称> <命名空间/KEY>",
                 "resolve": "jt resolve <引用或名称> [--env NAME] --exec <命令…>（默认注入 JT_SECRET）"]
    usageError("\(command) 已移到 jt：\(moved[command] ?? "jt ls / jt mv / jt resolve")")

case "bench":
    let n = args.count > 1 ? Int(args[1]) ?? 100_000 : 100_000
    print("inserting \(n) rows...")
    let insertStart = ContinuousClock.now
    let base = Date()
    for i in 0..<n {
        _ = try store.upsertText("合成条目 \(i) 包含一些中文内容 keyword\(i % 1000) mixed english text", at: base.addingTimeInterval(TimeInterval(i)))
    }
    print("insert: \(ContinuousClock.now - insertStart)")

    // bench 直接写库不走 pipeline，不会触发 prune；
    // 建议用 JIANTIEBAN_HOME 指向独立目录避免污染真实数据。
    let queries = ["keyword500", "中文内容", "合成条目 999", "不存在的东西xyz"]
    for q in queries {
        var samples: [Duration] = []
        for _ in 0..<20 {
            let t0 = ContinuousClock.now
            _ = try store.search(SearchQuery(parsing: q), page: 1, pageSize: 80)
            samples.append(ContinuousClock.now - t0)
        }
        samples.sort()
        let avg = samples.reduce(Duration.zero, +) / samples.count
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        print("query '\(q)': avg=\(avg) p95=\(p95)")
    }

case "stats":
    print("items=\(try store.count())")

case "clear":
    let files = try store.clear()
    ImageStore.removeFiles(files)
    print("cleared, \(files.count) image files removed")

case "version":
    print("jiantieban 0.2.0")

default:
    usageError("unknown command: \(command)")
}
}

do {
    try MainActor.assumeIsolated { try run() }
} catch {
    // 执行出错：一行原因 + 退出码 1，不再以未捕获错误崩溃
    FileHandle.standardError.write(Data("jiantieban: \(error.localizedDescription)\n".utf8))
    exit(1)
}
