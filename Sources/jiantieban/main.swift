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
    pipeline.policy = IngestPolicy(privacyMode: settings.privacyMode, autoExcludeSecrets: settings.autoExcludeSecrets)
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

@MainActor
func runBench(store: ClipStore, arguments: [String]) throws {

    let n = arguments.first.flatMap(Int.init) ?? 100_000
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

}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || ["_debug-panel", "_debug-scroll"].contains(args.first ?? "") {
    MainActor.assumeIsolated { runApp() }
}
let status = MainActor.assumeIsolated { HeadlessCLICommand.run(args) }
exit(status)
