import Foundation

/// 一次轮询读到的剪贴板快照
public struct PasteboardSnapshot: Sendable {
    public var changeCount: Int
    public var hasSelfMarker: Bool
    public var text: String?
    public var imagePNG: Data?

    public init(changeCount: Int, hasSelfMarker: Bool = false, text: String? = nil, imagePNG: Data? = nil) {
        self.changeCount = changeCount
        self.hasSelfMarker = hasSelfMarker
        self.text = text
        self.imagePNG = imagePNG
    }
}

/// 剪贴板读取抽象，便于测试时替换为假实现
@MainActor
public protocol PasteboardReading {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
}
