import Dispatch
import Foundation
import Vision

/// OCR 串行队列：进程内直接调 Vision，不起子进程。并发 1、队列上限 8、溢出丢最旧。
public final class OCRQueue: @unchecked Sendable {
    private let maxQueue = 8
    private let lock = NSLock()
    private var languages = ["zh-Hans", "zh-Hant", "en-US"]
    private var pending: [(itemID: Int64, imageURL: URL)] = []
    private var running = false
    private let worker = DispatchQueue(label: "rs.jiantieban.ocr")

    /// 结果回调，在主线程触发（Store 约定主线程使用）
    private let onResult: (Int64, String) -> Void

    public init(onResult: @escaping (Int64, String) -> Void) {
        self.onResult = onResult
    }

    /// OCR 识别语言，可由设置页覆盖；默认简体/繁体中文 + 英文。
    /// 设置页在主线程写、识别在后台线程读，两边都经过锁（以前直接读写同一个数组，是数据竞争）。
    public var recognitionLanguages: [String] {
        get { lock.withLock { languages } }
        set { lock.withLock { languages = newValue } }
    }

    public func enqueue(itemID: Int64, imageURL: URL) {
        lock.lock()
        pending.append((itemID, imageURL))
        if pending.count > maxQueue { pending.removeFirst() }
        let shouldStart = !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { worker.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                running = false
                lock.unlock()
                return
            }
            let job = pending.removeFirst()
            let languages = self.languages // 出队时取一份：识别途中改设置不影响这一张
            lock.unlock()

            if let text = recognize(imageURL: job.imageURL, languages: languages), !text.isEmpty {
                DispatchQueue.main.async { self.onResult(job.itemID, text) }
            }
        }
    }

    private func recognize(imageURL: URL, languages: [String]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        try? handler.perform([request])
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
