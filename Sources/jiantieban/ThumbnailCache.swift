import AppKit
import ImageIO

/// 列表预览缓存：主线程查缓存，未命中则后台用 ImageIO 出缩略图（不解码整张原图）。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// 列表 72pt 预览的点尺寸；解码按 2x，再加倍长边以免 16:9 方裁后短边不够。
    nonisolated static let previewPoint: CGFloat = 72
    nonisolated static let previewPixel = 144

    private let cache = NSCache<NSString, NSImage>()
    /// 解码中的路径 → 等结果的回调。解码期间列表重载会换一个 cell 来要同一张图，
    /// 每个请求者都要收到结果，否则新 cell 一直是空白占位。
    private var waiters: [String: [@Sendable (NSImage?) -> Void]] = [:]

    /// 命中则立即返回；未命中返回 nil 并后台生成正方形预览，完成后主线程回调。
    func preview(for path: String, completion: @escaping @Sendable (NSImage?) -> Void) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        if waiters[path] != nil {
            waiters[path]?.append(completion)
            return nil
        }
        waiters[path] = [completion]
        let pixel = Self.previewPixel
        let point = Self.previewPoint
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = SendableBox(Self.squarePreview(at: path, pixel: pixel, point: point))
            DispatchQueue.main.async {
                let callbacks = self.waiters.removeValue(forKey: path) ?? []
                if let img = decoded.value {
                    self.cache.setObject(img, forKey: path as NSString)
                }
                for callback in callbacks { callback(decoded.value) }
            }
        }
        return nil
    }

    /// 从原图生成中心方裁预览，列表里才能看出图而不是一条模糊带子。
    nonisolated private static func squarePreview(at path: String, pixel: Int, point: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixel * 2,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let side = min(cg.width, cg.height)
        guard side > 0 else { return nil }
        let rect = CGRect(
            x: (cg.width - side) / 2,
            y: (cg.height - side) / 2,
            width: side,
            height: side
        )
        let cropped = cg.cropping(to: rect) ?? cg
        return NSImage(cgImage: cropped, size: NSSize(width: point, height: point))
    }
}

private struct SendableBox: @unchecked Sendable {
    let value: NSImage?
    init(_ value: NSImage?) { self.value = value }
}
