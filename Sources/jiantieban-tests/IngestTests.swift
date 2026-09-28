import Core
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IngestTests {
    static var all: [TestCase] {
        [
            TestCase("text snapshot stored", testTextIngest),
            TestCase("image snapshot saved with thumbnail and dedupe", testImageIngest),
            TestCase("undecodable image data is rejected and leaves no files", testInvalidImageLeavesNoFiles),
            TestCase("failed image insert leaves no files behind", testFailedInsertLeavesNoFiles),
            TestCase("self marker snapshot ignored", testSelfMarker),
            TestCase("monitor only fires on changeCount change", testMonitorPolling),
            TestCase("ocr languages can be overridden", testOCRLanguages),
            TestCase("auto exclude skips detected secrets", testAutoExcludeSecrets),
        ]
    }

    @MainActor
    static func makeEngine() throws -> (ClipStore, IngestPipeline, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jiantieban-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try ClipStore(path: dir.appendingPathComponent("test.db").path)
        let imageStore = try ImageStore(directory: dir.appendingPathComponent("images"))
        return (store, IngestPipeline(store: store, imageStore: imageStore), dir)
    }

    /// 生成 100x50 PNG 测试图
    static func makePNG(width: Int = 100, height: Int = 50, seed: UInt8 = 0) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8((i / 4) % 256) &+ seed
            pixels[i + 3] = 255
        }
        let data = Data(pixels)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestFailure("no context") }
        context.data?.copyMemory(from: [UInt8](data), byteCount: data.count)
        guard let image = context.makeImage() else { throw TestFailure("no image") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw TestFailure("no dest")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @MainActor
    static func testTextIngest() throws {
        let (store, pipeline, _) = try makeEngine()
        pipeline.handle(PasteboardSnapshot(changeCount: 1, text: "hello"))
        try expectEqual(try store.count(), 1)
    }

    /// 回归：先写原图再校验——坏数据会在 images/ 留孤儿文件，且解不开的数据被当成 0×0 图片入库。
    static func testInvalidImageLeavesNoFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jtb-img-\(UUID().uuidString)")
        let images = try ImageStore(directory: dir)
        try expect((try? images.save(pngData: Data("not a png".utf8))) == nil, "garbage must be rejected")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// 回归：入库失败时，刚写好的原图和缩略图没人引用，留在 images/ 成孤儿。
    @MainActor
    static func testFailedInsertLeavesNoFiles() throws {
        let (store, pipeline, dir) = try makeEngine()
        let side = try SQLiteDB(path: dir.appendingPathComponent("test.db").path)
        try side.exec("CREATE TRIGGER fail_image BEFORE INSERT ON items WHEN NEW.kind = 'image' BEGIN SELECT RAISE(ABORT, 'simulated disk full'); END;")

        pipeline.handle(PasteboardSnapshot(changeCount: 1, imagePNG: try makePNG()))

        try expectEqual(try store.count(), 0)
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path), [])
    }

    @MainActor
    static func testImageIngest() throws {
        let (store, pipeline, _) = try makeEngine()
        let png = try makePNG()
        pipeline.handle(PasteboardSnapshot(changeCount: 1, imagePNG: png))

        let page = try store.search(SearchQuery(parsing: ":img"))
        try expectEqual(page.total, 1)
        let item = page.items[0]
        try expect(FileManager.default.fileExists(atPath: item.imagePath!), "original saved")
        try expect(FileManager.default.fileExists(atPath: item.thumbPath!), "thumb saved")
        try expect(item.thumbPath != item.imagePath, "100px image should get a separate 64px thumb")

        // 同一图片再次复制 → 去重，且不残留重复文件
        pipeline.handle(PasteboardSnapshot(changeCount: 2, imagePNG: png))
        try expectEqual(try store.count(), 1)
        let imagesDir = URL(fileURLWithPath: item.imagePath!).deletingLastPathComponent()
        let fileCount = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path).count
        try expectEqual(fileCount, 2, "only img + thumb remain")
    }

    @MainActor
    static func testSelfMarker() throws {
        let (store, pipeline, _) = try makeEngine()
        pipeline.handle(PasteboardSnapshot(changeCount: 1, hasSelfMarker: true, text: "self written"))
        try expectEqual(try store.count(), 0)
    }

    @MainActor
    static func testOCRLanguages() throws {
        let (_, pipeline, _) = try makeEngine()
        try expectEqual(pipeline.ocrLanguages, ["zh-Hans", "zh-Hant", "en-US"], "default OCR languages")
        pipeline.ocrLanguages = ["en-US"]
        try expectEqual(pipeline.ocrLanguages, ["en-US"], "OCR languages should be overridable")
    }

    @MainActor
    static func testAutoExcludeSecrets() throws {
        let (store, pipeline, _) = try makeEngine()
        pipeline.policy.autoExcludeSecrets = true
        pipeline.handle(PasteboardSnapshot(changeCount: 1, text: "sk-1234567890abcdefghij"))
        try expectEqual(try store.count(), 0, "detected secret should be skipped when autoExcludeSecrets is on")

        pipeline.handle(PasteboardSnapshot(changeCount: 2, text: "普通文本"))
        try expectEqual(try store.count(), 1, "normal text should still be stored")
    }

    @MainActor
    static func testMonitorPolling() throws {
        let fake = FakePasteboard()
        var fired: [PasteboardSnapshot] = []
        let monitor = ClipboardMonitor(pasteboard: fake) { fired.append($0) }

        monitor.poll()
        try expectEqual(fired.count, 0, "no change no fire")

        fake.changeCount = 2
        fake.nextText = "new copy"
        monitor.poll()
        try expectEqual(fired.count, 1)
        try expectEqual(fired[0].text, "new copy")

        monitor.poll()
        try expectEqual(fired.count, 1, "same changeCount no fire")
    }
}

@MainActor
final class FakePasteboard: PasteboardReading {
    var changeCount: Int = 1
    var nextText: String? = nil

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: changeCount, text: nextText)
    }
}
