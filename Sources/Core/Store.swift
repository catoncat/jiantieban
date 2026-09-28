import Foundation

public struct StoreConfig: Sendable {
    /// 非收藏条目保留时长（默认 24h）
    public var retentionSeconds: TimeInterval = 24 * 60 * 60
    /// 历史硬上限（默认 600）
    public var hardLimit: Int = 600
    /// 文本保存截断长度（默认 12000）
    public var maxSaveLength: Int = 12000
    /// 收藏是否永久保留（不被清理）。默认 true。
    public var favoritesPermanent: Bool = true

    public init(
        retentionSeconds: TimeInterval = 24 * 60 * 60,
        hardLimit: Int = 600,
        maxSaveLength: Int = 12000,
        favoritesPermanent: Bool = true
    ) {
        self.retentionSeconds = retentionSeconds
        self.hardLimit = hardLimit
        self.maxSaveLength = maxSaveLength
        self.favoritesPermanent = favoritesPermanent
    }
}

public struct PruneResult: Sendable {
    public var removedCount: Int = 0
    /// 需要调用方删除的图片文件（原图 + 缩略图）
    public var removedImageFiles: [String] = []
}

/// `description` 给 CLI / 日志（英文）；`errorDescription` 给面板 toast（用户看的中文）。
/// 不实现 LocalizedError 的错误在 toast 里只会显示 "The operation couldn’t be completed. (… error 1.)"。
public enum StoreError: Error, CustomStringConvertible, LocalizedError {
    case itemNotFound
    case notTextItem
    case alreadySecret
    case notSecret
    case restoreConflict

    public var description: String {
        switch self {
        case .itemNotFound: return "item not found"
        case .notTextItem: return "only text items can be marked as secret"
        case .alreadySecret: return "item is already a secret"
        case .notSecret: return "item is not a secret"
        case .restoreConflict: return "cannot restore: id or content is taken by a newer item"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "这条记录已经不在了"
        case .notTextItem: return "只有文本能标记为密钥"
        case .alreadySecret: return "已经是密钥了"
        case .notSecret: return "这条不是密钥"
        case .restoreConflict: return "撤销不了：这期间有新记录占了它的位置"
        }
    }
}

/// 撤销标记（写回明文）的结果。明文已作为普通记录存在时两条合并成一条，`mergedDuplicateID` 是被并掉删除的那条。
public struct UnmarkResult: Sendable {
    public let item: ClipItem
    public let mergedDuplicateID: Int64?
}

public struct SearchPage: Sendable {
    public var items: [ClipItem]
    public var total: Int
    public var page: Int
    public var pageSize: Int
}

/// 剪贴板历史存储：SQLite WAL + FTS5(trigram)。
/// 非线程安全，约定在 main actor 使用。
public final class ClipStore {
    private let db: SQLiteDB
    public var config: StoreConfig

    public init(path: String, config: StoreConfig = StoreConfig()) throws {
        self.db = try SQLiteDB(path: path)
        self.config = config
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try createSchema()
        try migrateItemColumns()
    }

    /// 内存库，供测试
    public convenience init(config: StoreConfig = StoreConfig()) throws {
        try self.init(path: ":memory:", config: config)
    }

    /// FTS 表 + 三个同步触发器。新建库与老库迁移（migrateFTS）共用这一份，改一处即两处生效。
    private static let ftsSchema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            content, ocr_text, image_path, secret_name, source_title, source_url,
            content = 'items', content_rowid = 'id',
            tokenize = 'trigram'
        );
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, content, ocr_text, image_path, secret_name, source_title, source_url)
            VALUES (new.id, new.content, new.ocr_text, new.image_path, new.secret_name, new.source_title, new.source_url);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, content, ocr_text, image_path, secret_name, source_title, source_url)
            VALUES ('delete', old.id, old.content, old.ocr_text, old.image_path, old.secret_name, old.source_title, old.source_url);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, content, ocr_text, image_path, secret_name, source_title, source_url)
            VALUES ('delete', old.id, old.content, old.ocr_text, old.image_path, old.secret_name, old.source_title, old.source_url);
            INSERT INTO items_fts(rowid, content, ocr_text, image_path, secret_name, source_title, source_url)
            VALUES (new.id, new.content, new.ocr_text, new.image_path, new.secret_name, new.source_title, new.source_url);
        END;

        """

    private func createSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL CHECK (kind IN ('text', 'image')),
            content TEXT NOT NULL,
            image_path TEXT,
            thumb_path TEXT,
            image_hash TEXT,
            ocr_text TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            is_secret INTEGER NOT NULL DEFAULT 0,
            secret_token TEXT,
            secret_type TEXT,
            secret_name TEXT,
            masked_preview TEXT,
            secret_missing INTEGER NOT NULL DEFAULT 0,
            was_pasted INTEGER NOT NULL DEFAULT 0,
            source_app TEXT,
            source_title TEXT,
            source_url TEXT,
            last_copied_at REAL NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_items_text_dedupe
            ON items(content) WHERE kind = 'text';
        CREATE UNIQUE INDEX IF NOT EXISTS idx_items_image_dedupe
            ON items(image_hash) WHERE kind = 'image' AND image_hash IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_items_recency ON items(last_copied_at DESC);
        """)
        try db.exec(Self.ftsSchema)
    }

    /// 迁移：为已装用户的旧库补列（新装库 CREATE TABLE 已含，ALTER 会被忽略）。
    private func migrateItemColumns() throws {
        let existing = Set(try columnNames())
        let needed: [(name: String, ddl: String)] = [
            ("is_secret", "ALTER TABLE items ADD COLUMN is_secret INTEGER NOT NULL DEFAULT 0"),
            ("secret_token", "ALTER TABLE items ADD COLUMN secret_token TEXT"),
            ("secret_type", "ALTER TABLE items ADD COLUMN secret_type TEXT"),
            ("secret_name", "ALTER TABLE items ADD COLUMN secret_name TEXT"),
            ("masked_preview", "ALTER TABLE items ADD COLUMN masked_preview TEXT"),
            ("secret_missing", "ALTER TABLE items ADD COLUMN secret_missing INTEGER NOT NULL DEFAULT 0"),
            ("was_pasted", "ALTER TABLE items ADD COLUMN was_pasted INTEGER NOT NULL DEFAULT 0"),
            ("source_app", "ALTER TABLE items ADD COLUMN source_app TEXT"),
            ("source_title", "ALTER TABLE items ADD COLUMN source_title TEXT"),
            ("source_url", "ALTER TABLE items ADD COLUMN source_url TEXT"),
        ]
        for col in needed where !existing.contains(col.name) {
            try db.exec(col.ddl)
        }
        try migrateFTS()
    }

    private func columnNames() throws -> [String] {
        let stmt = try db.prepare("PRAGMA table_info(items)")
        var names: [String] = []
        while try stmt.step() { names.append(stmt.columnText(1)) }
        return names
    }

    /// 旧库的 FTS 没有来源列；一个事务中重建，避免中途退出后索引只剩半截。
    private func migrateFTS() throws {
        let existing = Set(try ftsColumnNames())
        guard !existing.contains("source_url") else { return }
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("""
            DROP TRIGGER IF EXISTS items_ai;
            DROP TRIGGER IF EXISTS items_ad;
            DROP TRIGGER IF EXISTS items_au;
            DROP TABLE IF EXISTS items_fts;
            """ + Self.ftsSchema + """
            INSERT INTO items_fts(rowid, content, ocr_text, image_path, secret_name, source_title, source_url)
            SELECT id, content, ocr_text, image_path, secret_name, source_title, source_url FROM items;
            """)
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private func ftsColumnNames() throws -> [String] {
        let stmt = try db.prepare("PRAGMA table_info(items_fts)")
        var names: [String] = []
        while try stmt.step() { names.append(stmt.columnText(1)) }
        return names
    }

    // MARK: - 行映射

    private func rowToItem(_ stmt: SQLiteStmt) -> ClipItem {
        ClipItem(
            id: stmt.columnInt64(0),
            kind: ClipItemKind(rawValue: stmt.columnText(1)) ?? .text,
            content: stmt.columnText(2),
            imagePath: stmt.columnTextOrNil(3),
            thumbPath: stmt.columnTextOrNil(4),
            imageHash: stmt.columnTextOrNil(5),
            ocrText: stmt.columnTextOrNil(6),
            isFavorite: stmt.columnInt64(7) != 0,
            wasPasted: stmt.columnInt64(15) != 0,
            browserSource: stmt.columnTextOrNil(18).flatMap { url in
                guard let app = stmt.columnTextOrNil(16) else { return nil }
                return BrowserSource(bundleID: app, title: stmt.columnTextOrNil(17) ?? "", url: url)
            },
            isSecret: stmt.columnInt64(10) != 0,
            secretToken: stmt.columnTextOrNil(11),
            secretType: stmt.columnTextOrNil(12),
            secretName: stmt.columnTextOrNil(13),
            maskedPreview: stmt.columnTextOrNil(14),
            secretMissing: stmt.columnInt64(19) != 0,
            lastCopiedAt: Date(timeIntervalSince1970: stmt.columnDouble(8)),
            createdAt: Date(timeIntervalSince1970: stmt.columnDouble(9))
        )
    }

    private static let itemColumns =
        "id, kind, content, image_path, thumb_path, image_hash, ocr_text, is_favorite, last_copied_at, created_at, is_secret, secret_token, secret_type, secret_name, masked_preview, was_pasted, source_app, source_title, source_url, secret_missing"

    private func fetchItem(id: Int64) throws -> ClipItem? {
        let stmt = try db.prepare("SELECT \(Self.itemColumns) FROM items WHERE id = ?1")
        try stmt.bind(1, id)
        return try stmt.step() ? rowToItem(stmt) : nil
    }

    /// 按 id 获取单条记录。
    public func item(id: Int64) throws -> ClipItem? {
        try fetchItem(id: id)
    }

    // MARK: - 写入（去重：重复 → 刷新时间并顶到最前）

    /// 插入/去重一条普通文本记录。普通历史始终以明文存储；密钥化由 SecretManager 负责。
    @discardableResult
    public func upsertText(
        _ rawContent: String,
        at time: Date = Date()
    ) throws -> (item: ClipItem, inserted: Bool) {
        var content = rawContent
        if content.count > config.maxSaveLength {
            content = String(content.prefix(config.maxSaveLength))
        }
        if let existing = try findByContent(content, kind: .text) {
            try touch(id: existing.id, at: time)
            return (try fetchItem(id: existing.id)!, false)
        }
        let stmt = try db.prepare("""
            INSERT INTO items (kind, content, last_copied_at, created_at)
            VALUES ('text', ?1, ?2, ?2)
            """)
        try stmt.bind(1, content)
        try stmt.bind(2, time.timeIntervalSince1970)
        _ = try stmt.step()
        return (try fetchItem(id: db.lastInsertRowID)!, true)
    }

    /// 图片入库。若 hash 命中既有条目：刷新时间并返回 (既有条目, false)，
    /// 调用方应删除刚保存的重复图片文件。
    @discardableResult
    public func upsertImage(imagePath: String, thumbPath: String, hash: String, at time: Date = Date()) throws -> (item: ClipItem, inserted: Bool) {
        if let existing = try findByImageHash(hash) {
            try touch(id: existing.id, at: time)
            return (try fetchItem(id: existing.id)!, false)
        }
        let stmt = try db.prepare("""
            INSERT INTO items (kind, content, image_path, thumb_path, image_hash, last_copied_at, created_at)
            VALUES ('image', '[图片]', ?1, ?2, ?3, ?4, ?4)
            """)
        try stmt.bind(1, imagePath)
        try stmt.bind(2, thumbPath)
        try stmt.bind(3, hash)
        try stmt.bind(4, time.timeIntervalSince1970)
        _ = try stmt.step()
        return (try fetchItem(id: db.lastInsertRowID)!, true)
    }

    private func findByContent(_ content: String, kind: ClipItemKind) throws -> ClipItem? {
        let stmt = try db.prepare("SELECT \(Self.itemColumns) FROM items WHERE kind = ?1 AND content = ?2")
        try stmt.bind(1, kind.rawValue)
        try stmt.bind(2, content)
        return try stmt.step() ? rowToItem(stmt) : nil
    }

    private func findByImageHash(_ hash: String) throws -> ClipItem? {
        let stmt = try db.prepare("SELECT \(Self.itemColumns) FROM items WHERE kind = 'image' AND image_hash = ?1")
        try stmt.bind(1, hash)
        return try stmt.step() ? rowToItem(stmt) : nil
    }

    private func touch(id: Int64, at time: Date) throws {
        // 同内容重复制只认最近的一次来源；之前贴过的永久保留状态不清掉。
        let stmt = try db.prepare("UPDATE items SET last_copied_at = ?1, source_app = NULL, source_title = NULL, source_url = NULL WHERE id = ?2")
        try stmt.bind(1, time.timeIntervalSince1970)
        try stmt.bind(2, id)
        _ = try stmt.step()
    }

    /// 来源异步读回时必须仍是这一轮复制，防止前一轮较慢的浏览器查询覆盖最新来源。
    @discardableResult
    public func setBrowserSource(_ source: BrowserSource, forItemID id: Int64, copiedAt: Date) throws -> Bool {
        let stmt = try db.prepare("""
            UPDATE items SET source_app = ?1, source_title = ?2, source_url = ?3
            WHERE id = ?4 AND last_copied_at = ?5 AND is_secret = 0
            RETURNING id
            """)
        try stmt.bind(1, source.bundleID)
        try stmt.bind(2, source.title)
        try stmt.bind(3, source.url)
        try stmt.bind(4, id)
        try stmt.bind(5, copiedAt.timeIntervalSince1970)
        return try stmt.step()
    }

    /// 只有从本 App 发出贴回指令才调用；单纯复制到剪贴板不算。
    public func markPasted(id: Int64) throws {
        let stmt = try db.prepare("UPDATE items SET was_pasted = 1 WHERE id = ?1")
        try stmt.bind(1, id)
        _ = try stmt.step()
    }

    public func setOCRText(_ text: String, forItemID id: Int64) throws {
        let stmt = try db.prepare("UPDATE items SET ocr_text = ?1 WHERE id = ?2")
        try stmt.bind(1, text)
        try stmt.bind(2, id)
        _ = try stmt.step()
    }

    // MARK: - 密钥记录

    /// 把一条文本记录标记为密钥：content 改为密文，并记录 token / 类型 / 名称 / 遮罩。
    @discardableResult
    public func markAsSecret(
        id: Int64,
        encryptedContent: String,
        token: String,
        type: String?,
        name: String?,
        maskedPreview: String
    ) throws -> ClipItem {
        guard let item = try fetchItem(id: id) else { throw StoreError.itemNotFound }
        guard item.kind == .text else { throw StoreError.notTextItem }
        guard !item.isSecret else { throw StoreError.alreadySecret }
        let stmt = try db.prepare("""
            UPDATE items
            SET content = ?1, is_secret = 1, secret_token = ?2, secret_type = ?3,
                secret_name = ?4, masked_preview = ?5, secret_missing = 0,
                source_app = NULL, source_title = NULL, source_url = NULL
            WHERE id = ?6
            """)
        try stmt.bind(1, encryptedContent)
        try stmt.bind(2, token)
        try stmt.bind(3, type)
        try stmt.bind(4, name)
        try stmt.bind(5, maskedPreview)
        try stmt.bind(6, id)
        _ = try stmt.step()
        guard let updated = try fetchItem(id: id) else { throw StoreError.itemNotFound }
        return updated
    }

    /// 撤销标记：content 写回明文，清空密钥字段。只由 SecretManager.undoMark 调用（没有面向用户的取消密钥）。
    /// 明文已作为普通记录存在（撤销窗口内又复制了一次同样的值）时合并成一条：保留这条的 id，
    /// 最近复制时间取较新、任一收藏/贴回即保留，来源取较新的普通复制；删掉重复记录。一个事务里完成。
    @discardableResult
    public func unmarkSecret(id: Int64, plaintextContent: String) throws -> UnmarkResult {
        guard let item = try fetchItem(id: id) else { throw StoreError.itemNotFound }
        guard item.isSecret else { throw StoreError.notSecret }
        try db.exec("BEGIN IMMEDIATE")
        do {
            var lastCopiedAt = item.lastCopiedAt
            var isFavorite = item.isFavorite
            var wasPasted = item.wasPasted
            var source = item.browserSource
            var mergedID: Int64?
            if let duplicate = try findByContent(plaintextContent, kind: .text), duplicate.id != id {
                if duplicate.lastCopiedAt >= lastCopiedAt { source = duplicate.browserSource }
                lastCopiedAt = max(lastCopiedAt, duplicate.lastCopiedAt)
                isFavorite = isFavorite || duplicate.isFavorite
                wasPasted = wasPasted || duplicate.wasPasted
                let delete = try db.prepare("DELETE FROM items WHERE id = ?1")
                try delete.bind(1, duplicate.id)
                _ = try delete.step()
                mergedID = duplicate.id
            }
            let stmt = try db.prepare("""
                UPDATE items
                SET content = ?1, is_secret = 0, secret_token = NULL, secret_type = NULL,
                    secret_name = NULL, masked_preview = NULL, secret_missing = 0, last_copied_at = ?2, is_favorite = ?3,
                    was_pasted = ?4, source_app = ?5, source_title = ?6, source_url = ?7
                WHERE id = ?8
                """)
            try stmt.bind(1, plaintextContent)
            try stmt.bind(2, lastCopiedAt.timeIntervalSince1970)
            try stmt.bind(3, Int64(isFavorite ? 1 : 0))
            try stmt.bind(4, Int64(wasPasted ? 1 : 0))
            try stmt.bind(5, source?.bundleID)
            try stmt.bind(6, source?.title)
            try stmt.bind(7, source?.url)
            try stmt.bind(8, id)
            _ = try stmt.step()
            try db.exec("COMMIT")
            guard let updated = try fetchItem(id: id) else { throw StoreError.itemNotFound }
            return UnmarkResult(item: updated, mergedDuplicateID: mergedID)
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// 修改密钥记录的备注/名称。
    @discardableResult
    public func setSecretName(id: Int64, name: String) throws -> ClipItem {
        guard let item = try fetchItem(id: id) else { throw StoreError.itemNotFound }
        guard item.isSecret else { throw StoreError.notSecret }
        let stmt = try db.prepare("UPDATE items SET secret_name = ?1 WHERE id = ?2")
        try stmt.bind(1, name.isEmpty ? nil : name)
        try stmt.bind(2, id)
        _ = try stmt.step()
        guard let updated = try fetchItem(id: id) else { throw StoreError.itemNotFound }
        return updated
    }

    // MARK: - 引用记录的展示缓存（名称 / 遮罩 / 是否已从 jt 删除，以 jt 为准，ADR-0001）

    /// 有没有引用记录：没有就不必为展示缓存去读 jt。
    public func hasSecretReferences() throws -> Bool {
        let stmt = try db.prepare("SELECT EXISTS(SELECT 1 FROM items WHERE is_secret = 1 AND secret_token IS NOT NULL)")
        _ = try stmt.step()
        return stmt.columnInt64(0) != 0
    }

    /// 用 jt 的完整列表刷新引用记录：找得到的取 jt 的名称和遮罩，找不到的标为已删除。
    /// 只在拿到完整列表时调用（读失败不能当成"全删了"）。返回改动的行数。
    @discardableResult
    public func syncSecretReferences(with records: [SecretRecord]) throws -> Int {
        let byReference = Dictionary(records.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        let select = try db.prepare("""
            SELECT id, secret_token, secret_name, masked_preview, secret_missing
            FROM items WHERE is_secret = 1 AND secret_token IS NOT NULL
            """)
        var updates: [(id: Int64, name: String?, preview: String?, missing: Bool)] = []
        while try select.step() {
            let id = select.columnInt64(0)
            let name = select.columnTextOrNil(2)
            let preview = select.columnTextOrNil(3)
            let missing = select.columnInt64(4) != 0
            if let record = byReference[select.columnText(1)] {
                if name != record.name || preview != record.preview || missing {
                    updates.append((id, record.name, record.preview, false))
                }
            } else if !missing {
                updates.append((id, name, preview, true))
            }
        }
        guard !updates.isEmpty else { return 0 }
        try db.exec("BEGIN IMMEDIATE")
        do {
            for update in updates {
                let stmt = try db.prepare("UPDATE items SET secret_name = ?1, masked_preview = ?2, secret_missing = ?3 WHERE id = ?4")
                try stmt.bind(1, update.name)
                try stmt.bind(2, update.preview)
                try stmt.bind(3, Int64(update.missing ? 1 : 0))
                try stmt.bind(4, update.id)
                _ = try stmt.step()
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        return updates.count
    }

    /// jt 里改了名：持有这个引用的记录跟着改。
    public func renameSecretReferences(token: String, name: String) throws {
        let stmt = try db.prepare("UPDATE items SET secret_name = ?1, secret_missing = 0 WHERE is_secret = 1 AND secret_token = ?2")
        try stmt.bind(1, name)
        try stmt.bind(2, token)
        _ = try stmt.step()
    }

    /// jt 里删了：持有这个引用的记录标为已删除（记录本身留着，按普通保留策略处理）。
    public func markSecretReferencesMissing(token: String) throws {
        let stmt = try db.prepare("UPDATE items SET secret_missing = 1 WHERE is_secret = 1 AND secret_token = ?1")
        try stmt.bind(1, token)
        _ = try stmt.step()
    }

    /// 按 token 查找密钥记录。
    public func item(bySecretToken token: String) throws -> ClipItem? {
        let stmt = try db.prepare("SELECT \(Self.itemColumns) FROM items WHERE secret_token = ?1 LIMIT 1")
        try stmt.bind(1, token)
        return try stmt.step() ? rowToItem(stmt) : nil
    }

    // MARK: - 收藏 / 删除 / 清空

    /// 切换收藏，返回新状态
    @discardableResult
    public func toggleFavorite(id: Int64) throws -> Bool {
        let stmt = try db.prepare("UPDATE items SET is_favorite = 1 - is_favorite WHERE id = ?1 RETURNING is_favorite")
        try stmt.bind(1, id)
        guard try stmt.step() else { return false }
        return stmt.columnInt64(0) != 0
    }

    /// 直接设置收藏状态（导入器用）
    public func setFavorite(_ favorite: Bool, id: Int64) throws {
        let stmt = try db.prepare("UPDATE items SET is_favorite = ?1 WHERE id = ?2")
        try stmt.bind(1, Int64(favorite ? 1 : 0))
        try stmt.bind(2, id)
        _ = try stmt.step()
    }

    /// 删除条目，返回被删条目（调用方清理图片文件）
    @discardableResult
    public func delete(id: Int64) throws -> ClipItem? {
        guard let item = try fetchItem(id: id) else { return nil }
        let stmt = try db.prepare("DELETE FROM items WHERE id = ?1")
        try stmt.bind(1, id)
        _ = try stmt.step()
        return item
    }

    /// 把删掉的记录按原字段放回（撤销删除）：id、内容、收藏、时间、OCR 文字、密钥字段都不变。
    /// 删除后又入库了同样内容的记录、或新记录复用了这个 id（SQLite 会复用最大 id）时抛 restoreConflict，不覆盖新记录。
    public func restore(_ item: ClipItem) throws {
        if try fetchItem(id: item.id) != nil { throw StoreError.restoreConflict }
        switch item.kind {
        case .text:
            if try findByContent(item.content, kind: .text) != nil { throw StoreError.restoreConflict }
        case .image:
            if let hash = item.imageHash, try findByImageHash(hash) != nil { throw StoreError.restoreConflict }
        }
        let stmt = try db.prepare("""
            INSERT INTO items (\(Self.itemColumns))
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
            """)
        try stmt.bind(1, item.id)
        try stmt.bind(2, item.kind.rawValue)
        try stmt.bind(3, item.content)
        try stmt.bind(4, item.imagePath)
        try stmt.bind(5, item.thumbPath)
        try stmt.bind(6, item.imageHash)
        try stmt.bind(7, item.ocrText)
        try stmt.bind(8, Int64(item.isFavorite ? 1 : 0))
        try stmt.bind(9, item.lastCopiedAt.timeIntervalSince1970)
        try stmt.bind(10, item.createdAt.timeIntervalSince1970)
        try stmt.bind(11, Int64(item.isSecret ? 1 : 0))
        try stmt.bind(12, item.secretToken)
        try stmt.bind(13, item.secretType)
        try stmt.bind(14, item.secretName)
        try stmt.bind(15, item.maskedPreview)
        try stmt.bind(16, Int64(item.wasPasted ? 1 : 0))
        try stmt.bind(17, item.browserSource?.bundleID)
        try stmt.bind(18, item.browserSource?.title)
        try stmt.bind(19, item.browserSource?.url)
        try stmt.bind(20, Int64(item.secretMissing ? 1 : 0))
        _ = try stmt.step()
    }

    /// 清空全部，返回需清理的图片文件
    public func clear() throws -> [String] {
        var files: [String] = []
        let stmt = try db.prepare("SELECT image_path, thumb_path FROM items WHERE kind = 'image'")
        while try stmt.step() {
            if let p = stmt.columnTextOrNil(0) { files.append(p) }
            if let p = stmt.columnTextOrNil(1), p != stmt.columnTextOrNil(0) { files.append(p) }
        }
        try db.exec("DELETE FROM items")
        return files
    }

    // MARK: - 保留策略（24h + 600 上限，收藏豁免）

    @discardableResult
    public func prune(now: Date = Date()) throws -> PruneResult {
        var result = PruneResult()

        let cutoff = now.timeIntervalSince1970 - config.retentionSeconds
        // favoritesPermanent=true 时收藏豁免清理；
        // 为 false 时收藏与其他条目一视同仁。
        let favoriteGuard = config.favoritesPermanent ? "is_favorite = 0 AND " : ""
        let byAge = try db.prepare("""
            DELETE FROM items WHERE was_pasted = 0 AND \(favoriteGuard)last_copied_at < ?1
            RETURNING image_path, thumb_path
            """)
        try byAge.bind(1, cutoff)
        while try byAge.step() {
            result.removedCount += 1
            collectImageFiles(byAge, into: &result.removedImageFiles)
        }

        let byLimit: SQLiteStmt
        if config.favoritesPermanent {
            byLimit = try db.prepare("""
                DELETE FROM items WHERE was_pasted = 0 AND is_favorite = 0 AND id NOT IN (
                    SELECT id FROM items WHERE was_pasted = 0 AND is_favorite = 0
                    ORDER BY last_copied_at DESC LIMIT ?1
                ) RETURNING image_path, thumb_path
                """)
        } else {
            byLimit = try db.prepare("""
                DELETE FROM items WHERE was_pasted = 0 AND id NOT IN (
                    SELECT id FROM items WHERE was_pasted = 0
                    ORDER BY last_copied_at DESC LIMIT ?1
                ) RETURNING image_path, thumb_path
                """)
        }
        try byLimit.bind(1, Int64(config.hardLimit))
        while try byLimit.step() {
            result.removedCount += 1
            collectImageFiles(byLimit, into: &result.removedImageFiles)
        }

        return result
    }

    private func collectImageFiles(_ stmt: SQLiteStmt, into files: inout [String]) {
        if let p = stmt.columnTextOrNil(0) { files.append(p) }
        let thumb = stmt.columnTextOrNil(1)
        if let thumb, thumb != stmt.columnTextOrNil(0) { files.append(thumb) }
    }

    // MARK: - 查询

    public func count() throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM items")
        _ = try stmt.step()
        return Int(stmt.columnInt64(0))
    }

    private static let selectColumns =
        "i.id, i.kind, i.content, i.image_path, i.thumb_path, i.image_hash, i.ocr_text, i.is_favorite, i.last_copied_at, i.created_at, i.is_secret, i.secret_token, i.secret_type, i.secret_name, i.masked_preview, i.was_pasted, i.source_app, i.source_title, i.source_url, i.secret_missing"

    /// LIKE 通配符转义（配 ESCAPE '\\'）
    private func escapeLike(_ s: String) -> String {
        s.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
    }

    /// 列表（无关键词）或搜索。trigram FTS 需要 ≥3 字符，更短的关键词退化为 LIKE 子串。
    public func search(_ query: SearchQuery, page: Int = 1, pageSize: Int = 80) throws -> SearchPage {
        func filterParts(alias: String) -> [String] {
            var parts: [String] = []
            if let kind = query.kindFilter {
                parts.append("\(alias).kind = '\(kind.rawValue)'")
            }
            if query.favoritesOnly {
                parts.append("\(alias).is_favorite = 1")
            }
            if query.secretsOnly {
                parts.append("\(alias).is_secret = 1")
            }
            return parts
        }

        var matchWhere: [String] = []
        var keywordParam: String? = nil
        var joinsFTS = false

        let keyword = query.keyword.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            if keyword.count >= 3 {
                joinsFTS = true
                // FTS5 短语查询：双引号包裹得到子串语义（trigram 分词器）
                keywordParam = "\"" + keyword.replacing("\"", with: "\"\"") + "\""
                matchWhere.append("items_fts MATCH ?1")
            } else {
                keywordParam = "%" + escapeLike(keyword) + "%"
                matchWhere.append("(i.content LIKE ?1 ESCAPE '\\' OR i.ocr_text LIKE ?1 ESCAPE '\\' OR i.image_path LIKE ?1 ESCAPE '\\' OR i.secret_name LIKE ?1 ESCAPE '\\' OR i.source_title LIKE ?1 ESCAPE '\\' OR i.source_url LIKE ?1 ESCAPE '\\')")
            }
        }

        let whereParts = filterParts(alias: "i") + matchWhere
        let whereSQL = whereParts.isEmpty ? "" : "WHERE " + whereParts.joined(separator: " AND ")
        let fromSQL = joinsFTS
            ? "FROM items i JOIN items_fts ON items_fts.rowid = i.id"
            : "FROM items i"
        let kwOffset: Int32 = keywordParam != nil ? 1 : 0

        func bindAll(_ stmt: SQLiteStmt, paging: Bool) throws {
            if let keywordParam { try stmt.bind(1, keywordParam) }
            if paging {
                let page = max(1, page)
                try stmt.bind(1 + kwOffset, Int64(pageSize))
                try stmt.bind(2 + kwOffset, Int64((page - 1) * pageSize))
            }
        }

        // 快速路径：无条目级过滤的 FTS 查询直接数 FTS 表，避免 10 万级 rowid JOIN
        let useFastCount = joinsFTS && query.kindFilter == nil && !query.favoritesOnly && !query.secretsOnly
        let countSQL = useFastCount
            ? "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH ?1"
            : "SELECT COUNT(*) \(fromSQL) \(whereSQL)"
        let totalStmt = try db.prepare(countSQL)
        try bindAll(totalStmt, paging: false)
        guard try totalStmt.step() else {
            return SearchPage(items: [], total: 0, page: page, pageSize: pageSize)
        }
        let total = Int(totalStmt.columnInt64(0))

        let stmt: SQLiteStmt
        if joinsFTS {
            // 两阶段：内层只排序 (id, last_copied_at) 轻行，避免对 10 万条宽行建临时 B-tree；
            // 外层按主键回取 80 条宽行。
            let innerParts = filterParts(alias: "i2") + (keywordParam != nil ? ["items_fts MATCH ?1"] : [])
            let innerWhere = innerParts.isEmpty ? "" : "WHERE " + innerParts.joined(separator: " AND ")
            stmt = try db.prepare("""
                SELECT \(Self.selectColumns)
                FROM items i
                JOIN (
                    SELECT i2.id AS id, i2.last_copied_at AS lca
                    FROM items i2 JOIN items_fts ON items_fts.rowid = i2.id
                    \(innerWhere)
                    ORDER BY i2.last_copied_at DESC
                    LIMIT ?\(1 + kwOffset) OFFSET ?\(2 + kwOffset)
                ) r ON r.id = i.id
                ORDER BY r.lca DESC
                """)
        } else {
            stmt = try db.prepare("""
                SELECT \(Self.selectColumns) \(fromSQL) \(whereSQL)
                ORDER BY i.last_copied_at DESC
                LIMIT ?\(1 + kwOffset) OFFSET ?\(2 + kwOffset)
                """)
        }
        try bindAll(stmt, paging: true)

        var items: [ClipItem] = []
        while try stmt.step() { items.append(rowToItem(stmt)) }
        return SearchPage(items: items, total: total, page: max(1, page), pageSize: pageSize)
    }
}
