import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct SavedImage: Sendable {
    public var imagePath: String
    public var thumbPath: String
    public var hash: String
    public var width: Int
    public var height: Int
}

/// 图片落盘：原图 PNG + 64px 缩略图（ImageIO）+ SHA256（CryptoKit），都在进程内，不起子进程
public final class ImageStore {
    public var thumbMaxPixel: Int = 64
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(pngData: Data, now: Date = Date()) throws -> SavedImage {
        // 先校验再落盘：解不开（或解出 0×0）的数据不写任何文件。
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = props[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
            throw CocoaError(.coderReadCorrupt)
        }

        let id = "\(Int(now.timeIntervalSince1970))_\(Int.random(in: 1000...9999))"
        let imageURL = directory.appendingPathComponent("img_\(id).png")
        let thumbURL = directory.appendingPathComponent("thumb_\(id).png")
        try pngData.write(to: imageURL, options: .atomic)
        // 小图、或缩略图写失败：直接用原图作缩略图
        let thumbPath = writeThumbnail(from: source, to: thumbURL, longestSide: max(width, height)) ?? imageURL.path

        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        return SavedImage(imagePath: imageURL.path, thumbPath: thumbPath, hash: hash, width: width, height: height)
    }

    private func writeThumbnail(from source: CGImageSource, to url: URL, longestSide: Int) -> String? {
        guard longestSide > thumbMaxPixel,
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: thumbMaxPixel,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
              ] as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url.path
    }

    public static func removeFiles(_ paths: [String]) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
