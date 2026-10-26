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

        let id = UUID().uuidString
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

    /// Cleanup is restricted to regular files directly owned by this image store.
    /// Never follow database-supplied paths outside the managed directory.
    public func removeFiles(_ paths: [String]) {
        Self.removeFiles(paths, in: directory)
    }

    public static func removeFiles(_ paths: [String], in directory: URL? = nil) {
        let manager = FileManager.default
        let root: URL
        if let directory {
            root = directory
        } else if let home = ProcessInfo.processInfo.environment["JIANTIEBAN_HOME"] {
            root = URL(fileURLWithPath: home).appendingPathComponent("images")
        } else {
            guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            root = support.appendingPathComponent("jiantieban/images")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            // Files are generated directly in images/, never in subdirectories.
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalRoot,
                  url.resolvingSymlinksInPath().deletingLastPathComponent().path == canonicalRoot,
                  let attributes = try? manager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
