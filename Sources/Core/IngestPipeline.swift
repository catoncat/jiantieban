import Foundation

/// 采集策略：隐私模式 + 自动排除疑似密钥。
/// 密钥的“标记/加密”仍由用户显式触发（SecretManager）；自动排除是额外安全选项。
public struct IngestPolicy: Sendable {
    public var privacyMode: Bool = false
    /// 开启后，命中 SecretDetector 的文本不会进入历史（直接丢弃）。
    public var autoExcludeSecrets: Bool = false

    public init(privacyMode: Bool = false, autoExcludeSecrets: Bool = false) {
        self.privacyMode = privacyMode
        self.autoExcludeSecrets = autoExcludeSecrets
    }
}

/// 采集管道：快照 → 去重入库 → 图片落盘 → OCR → 保留策略。
@MainActor
public final class IngestPipeline {
    private let store: ClipStore
    private let imageStore: ImageStore
    private let ocr: OCRQueue

    /// 运行时采集策略（隐私模式），由设置驱动
    public var policy = IngestPolicy()

    /// OCR 识别语言，透传给 OCRQueue（可由设置页覆盖）。
    public var ocrLanguages: [String] {
        get { ocr.recognitionLanguages }
        set { ocr.recognitionLanguages = newValue }
    }

    public init(store: ClipStore, imageStore: ImageStore) {
        self.store = store
        self.imageStore = imageStore
        self.ocr = OCRQueue(onResult: { [weak store] itemID, text in
            try? store?.setOCRText(text, forItemID: itemID)
        })
    }

    /// 处理一次剪贴板变化；返回这次实际保存的记录，用于稍后关联浏览器来源。
    @discardableResult
    public func handle(_ snapshot: PasteboardSnapshot) -> ClipItem? {
        guard !snapshot.hasSelfMarker else { return nil }

        // 隐私模式：本次会话完全不记录
        guard !policy.privacyMode else { return nil }

        // 自动排除疑似密钥：高置信命中时不入库
        if policy.autoExcludeSecrets,
           let text = snapshot.text,
           SecretDetector.detect(text) != nil {
            return nil
        }

        do {
            let item: ClipItem?
            if let png = snapshot.imagePNG {
                item = try handleImage(png)
            } else if let text = snapshot.text, !text.isEmpty {
                item = try store.upsertText(text).item
            } else {
                item = nil
            }
            try applyPrune()
            return item
        } catch {
            FileHandle.standardError.write("ingest error: \(error)\n".data(using: .utf8)!)
            return nil
        }
    }

    private func handleImage(_ png: Data) throws -> ClipItem {
        let saved = try imageStore.save(pngData: png)
        let item: ClipItem
        let inserted: Bool
        do {
            (item, inserted) = try store.upsertImage(
                imagePath: saved.imagePath, thumbPath: saved.thumbPath, hash: saved.hash
            )
        } catch {
            // 入库失败：刚写的文件没人引用，删掉再报错
            ImageStore.removeFiles([saved.imagePath, saved.thumbPath])
            throw error
        }
        if inserted {
            ocr.enqueue(itemID: item.id, imageURL: URL(fileURLWithPath: saved.imagePath))
        } else {
            // 重复图片：删除刚保存的文件
            ImageStore.removeFiles([saved.imagePath, saved.thumbPath])
        }
        return item
    }

    private func applyPrune() throws {
        let result = try store.prune()
        if !result.removedImageFiles.isEmpty {
            ImageStore.removeFiles(result.removedImageFiles)
        }
    }
}
