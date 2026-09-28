import Foundation

/// 定时轮询剪贴板 changeCount（默认 0.8s）。
/// 变化时回调快照；由调用方（IngestPipeline）决定存什么。
@MainActor
public final class ClipboardMonitor {
    public var interval: TimeInterval
    private let pasteboard: any PasteboardReading
    private let onChange: (PasteboardSnapshot) -> Void
    private var timer: Timer?
    private var lastChangeCount: Int

    public init(
        pasteboard: any PasteboardReading,
        interval: TimeInterval = 0.8,
        onChange: @escaping (PasteboardSnapshot) -> Void
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.onChange = onChange
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        onChange(pasteboard.snapshot())
    }
}
