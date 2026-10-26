import Foundation
import Dispatch
@testable import Core

/// Each worker opens and exclusively uses its own connection, as GUI/CLI processes do.
private final class StoreWorkerFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        values.append(String(describing: error))
    }
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

enum HeadlessStoreTests {
    static var all: [TestCase] {
        [
            TestCase("headless store concurrent open and dedupe", concurrentWriters),
            TestCase("headless store concurrent first open configures WAL", concurrentFirstOpen),
            TestCase("headless store favorite is idempotent and missing is an error", favorite),
            TestCase("headless store equal timestamp ordering and pagination validation", ordering),
            TestCase("headless image cleanup is confined to managed regular files", cleanup),
            TestCase("headless images saved at the same instant have unique paths", uniqueImageNames),
            TestCase("headless store transaction rollback leaves connection usable", rollback),
            TestCase("headless store delayed paste retention cannot mark a reused ID", pasteRetentionIdentity),
            TestCase("headless store stale OCR cannot change a replacement record", ocrIdentity),
            TestCase("headless store reference sync reads after acquiring its writer lock", referenceSyncIdentity),
        ]
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jtb-headless-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func concurrentWriters() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.db").path
        // Seed a real old schema. Each worker must recheck columns under migration lock.
        do {
            let old = try SQLiteDB(path: path)
            try old.exec("""
                CREATE TABLE items (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, content TEXT NOT NULL,
                    image_path TEXT, thumb_path TEXT, image_hash TEXT, ocr_text TEXT,
                    is_favorite INTEGER NOT NULL DEFAULT 0, last_copied_at REAL NOT NULL, created_at REAL NOT NULL);
                CREATE VIRTUAL TABLE items_fts USING fts5(content, ocr_text, image_path,
                    content = 'items', content_rowid = 'id', tokenize = 'trigram');
                """)
        }
        let failures = StoreWorkerFailures()
        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            do {
                let store = try ClipStore(path: path)
                for iteration in 0..<12 {
                    _ = try store.upsertText("shared text")
                    _ = try store.upsertImage(imagePath: "unused.png", thumbPath: "unused.png", hash: "shared-hash")
                    _ = try store.upsertText("unique \(worker) \(iteration)")
                }
            } catch { failures.append(error) }
        }
        try expect(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
        let store = try ClipStore(path: path)
        try expectEqual(try store.count(), 74)
        try expectEqual(try store.search(SearchQuery(keyword: "shared text")).total, 1)
    }

    static func concurrentFirstOpen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Exercise journal-mode negotiation on an absent database as well as the
        // old-schema migration path above. Every worker owns its own connection.
        for attempt in 0..<3 {
            let path = directory.appendingPathComponent("fresh-\(attempt).db").path
            let failures = StoreWorkerFailures()
            DispatchQueue.concurrentPerform(iterations: 6) { worker in
                do {
                    let store = try ClipStore(path: path)
                    _ = try store.upsertText("first-open \(worker)")
                } catch { failures.append(error) }
            }
            try expect(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
            let store = try ClipStore(path: path)
            try expectEqual(try store.count(), 6)
        }
    }

    static func favorite() throws {
        let store = try ClipStore()
        let item = try store.upsertText("favorite test").item
        try expect(try store.setFavorite(true, id: item.id).isFavorite)
        try expect(try store.setFavorite(true, id: item.id).isFavorite)
        try expect(!(try store.setFavorite(false, id: item.id).isFavorite))
        _ = try store.delete(id: item.id)
        try expect(try store.delete(id: item.id) == nil)
        do {
            _ = try store.setFavorite(true, id: item.id)
            throw TestFailure("missing favorite setter must fail")
        } catch StoreError.itemNotFound {}
        do {
            _ = try store.toggleFavorite(id: item.id)
            throw TestFailure("missing favorite toggle must fail")
        } catch StoreError.itemNotFound {}
    }

    static func ordering() throws {
        let store = try ClipStore()
        let time = Date(timeIntervalSince1970: 100)
        let first = try store.upsertText("common first", at: time).item
        let second = try store.upsertText("common second", at: time).item
        for query in [SearchQuery(), SearchQuery(keyword: "co"), SearchQuery(keyword: "common")] {
            try expectEqual(try store.search(query, page: 1, pageSize: 1).items.first?.id, second.id)
            try expectEqual(try store.search(query, page: 2, pageSize: 1).items.first?.id, first.id)
        }
        try expectEqual(try store.latestItem()?.id, second.id)
        for (page, size) in [(0, 1), (1, 0), (Int.max, 2)] {
            do {
                _ = try store.search(SearchQuery(), page: page, pageSize: size)
                throw TestFailure("invalid pagination must fail")
            } catch StoreError.invalidPagination {}
        }
    }

    static func cleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("images")
        let images = try ImageStore(directory: root)
        let inside = root.appendingPathComponent("owned.png")
        let outside = directory.appendingPathComponent("keep.png")
        let link = root.appendingPathComponent("link.png")
        let subdirectory = root.appendingPathComponent("keep-directory")
        try Data([1]).write(to: inside)
        try Data([2]).write(to: outside)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: directory)
        images.removeFiles([inside.path, outside.path, link.path, subdirectory.path, escape.appendingPathComponent("keep.png").path])
        try expect(!FileManager.default.fileExists(atPath: inside.path))
        try expect(FileManager.default.fileExists(atPath: outside.path))
        try expect(FileManager.default.fileExists(atPath: link.path))
        try expect(FileManager.default.fileExists(atPath: subdirectory.path))
        // A deliberately configured root symlink is valid; child symlink escapes are not.
        let alias = directory.appendingPathComponent("images-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliasedFile = alias.appendingPathComponent("owned-alias.png")
        try Data([3]).write(to: aliasedFile)
        ImageStore.removeFiles([aliasedFile.path], in: alias)
        try expect(!FileManager.default.fileExists(atPath: aliasedFile.path))
    }

    static func uniqueImageNames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try ImageStore(directory: directory)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        let time = Date(timeIntervalSince1970: 123)
        let first = try images.save(pngData: png, now: time)
        let second = try images.save(pngData: png, now: time)
        try expect(first.imagePath != second.imagePath)
        try expectEqual(first.hash, second.hash)
        images.removeFiles([second.imagePath, second.thumbPath])
        try expect(FileManager.default.fileExists(atPath: first.imagePath))
    }

    static func rollback() throws {
        let db = try SQLiteDB(path: ":memory:")
        try db.exec("CREATE TABLE sample(value INTEGER)")
        do {
            try db.transaction {
                try db.exec("INSERT INTO sample VALUES (1)")
                throw TestFailure("rollback sentinel")
            }
        } catch is TestFailure {}
        try db.transaction {
            try db.exec("INSERT INTO sample VALUES (2)")
            do {
                try db.transaction { try db.exec("INSERT INTO sample VALUES (99)") }
                throw TestFailure("nested transaction must fail")
            } catch is SQLiteError {}
            // A failed nested BEGIN must not roll back this outer transaction.
            try db.exec("INSERT INTO sample VALUES (3)")
        }
        let stmt = try db.prepare("SELECT COUNT(*), SUM(value) FROM sample")
        _ = try stmt.step()
        try expectEqual(stmt.columnInt64(0), 2)
        try expectEqual(stmt.columnInt64(1), 5)
    }

    static func pasteRetentionIdentity() throws {
        let store = try ClipStore()
        let original = try store.upsertText("original", at: Date(timeIntervalSince1970: 1)).item
        _ = try store.setFavorite(true, id: original.id)
        try store.markPasted(id: original.id, expectedItem: original)
        try expect(try store.item(id: original.id)?.wasPasted == true, "metadata changes do not change row identity")
        _ = try store.delete(id: original.id)
        let replacement = try store.upsertText("replacement", at: Date(timeIntervalSince1970: 2)).item
        try expectEqual(replacement.id, original.id)
        do {
            try store.markPasted(id: original.id, expectedItem: original)
            throw TestFailure("a delayed paste must not retain a replacement record")
        } catch StoreError.itemChanged {}
        try expect(try store.item(id: replacement.id)?.wasPasted == false)
        _ = try store.delete(id: replacement.id)
        do {
            try store.markPasted(id: original.id, expectedItem: original)
            throw TestFailure("retaining a missing record must report failure")
        } catch StoreError.itemNotFound {}
    }

    static func ocrIdentity() throws {
        let store = try ClipStore()
        let original = try store.upsertImage(imagePath: "original.png", thumbPath: "original.png", hash: "original").item
        try expect(try store.setOCRText("original OCR", forItemID: original.id, expectedImagePath: "original.png"))
        _ = try store.delete(id: original.id)
        let replacement = try store.upsertImage(imagePath: "replacement.png", thumbPath: "replacement.png", hash: "replacement").item
        try expectEqual(replacement.id, original.id)
        try expect(!(try store.setOCRText("stale OCR", forItemID: original.id, expectedImagePath: "original.png")))
        try expect(try store.item(id: replacement.id)?.ocrText == nil)
        try expect(try store.setOCRText("replacement OCR", forItemID: replacement.id, expectedImagePath: "replacement.png"))
        _ = try store.delete(id: replacement.id)
        let text = try store.upsertText("ordinary replacement").item
        try expectEqual(text.id, original.id)
        try expect(!(try store.setOCRText("stale OCR", forItemID: original.id, expectedImagePath: "original.png")))
        try expect(try store.item(id: text.id)?.ocrText == nil)
    }

    static func referenceSyncIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.db").path
        let store = try ClipStore(path: path)
        let original = try store.upsertText("synthetic value").item
        _ = try store.markAsSecret(id: original.id, encryptedContent: "jt://secret/synthetic",
            token: "jt://secret/synthetic", type: nil, name: "old", maskedPreview: "sy****ue")
        let writer = try SQLiteDB(path: path)
        let ready = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let failures = StoreWorkerFailures()
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let reader = try ClipStore(path: path)
                ready.signal()
                guard go.wait(timeout: .now() + 5) == .success else { throw TestFailure("reference sync was not released") }
                _ = try reader.syncSecretReferences(with: [SecretRecord(id: "synthetic", reference: "jt://secret/synthetic", name: "new", preview: "sy****ue")])
            } catch { failures.append(error); ready.signal() }
        }
        defer { go.signal() }
        try expect(ready.wait(timeout: .now() + 5) == .success)
        try expect(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
        try writer.transaction {
            go.signal()
            // An old implementation reads the committed reference before blocking
            // on BEGIN. The fixed implementation blocks before reading any rows.
            Thread.sleep(forTimeInterval: 0.1)
            try writer.exec("DELETE FROM items; INSERT INTO items(kind, content, last_copied_at, created_at) VALUES ('text', 'replacement', 2, 2)")
        }
        try expect(done.wait(timeout: .now() + 5) == .success)
        try expect(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
        let replacement = try unwrap(try store.item(id: original.id))
        try expectEqual(replacement.content, "replacement")
        try expect(!replacement.isSecret && replacement.secretName == nil && replacement.maskedPreview == nil)
    }
}
