import Foundation
@testable import Core

enum StoreTests {
    static func makeStore() throws -> ClipStore {
        try ClipStore()
    }

    static var all: [TestCase] {
        [
            TestCase("insert and list text", testInsertAndList),
            TestCase("text dedupe refreshes recency", testTextDedupe),
            TestCase("SQLite text reads preserve embedded NUL and distinguish NULL from empty", testSQLiteTextReads),
            TestCase("剪贴板记录保留 NUL 前后的 UTF-8 文本且不会误去重", testEmbeddedNULText),
            TestCase("image dedupe by hash", testImageDedupe),
            TestCase("text truncation at 12000", testTruncation),
            TestCase("favorite survives prune by age", testFavoriteSurvivesPrune),
            TestCase("从 App 贴回过的记录不受时长和条数限制", testPastedSurvivesPrune),
            TestCase("同内容重复复制只留最新来源，异步旧结果不得覆盖", testSourceFollowsLatestCopy),
            TestCase("applying a history config prunes existing rows immediately", testApplyConfigAndPrune),
            TestCase("favorite is pruned by age when favoritesPermanent is false", testFavoritePrunedByAgeWhenNotPermanent),
            TestCase("favorite is included in hard limit when favoritesPermanent is false", testFavoriteIncludedInHardLimitWhenNotPermanent),
            TestCase("prune enforces hard limit", testHardLimit),
            TestCase("delete returns item for file cleanup", testDelete),
            TestCase("legacy schema upgrades: old rows searchable, secret names searchable", testLegacySchemaMigrates),
            TestCase("search query parsing parity", testQueryParsing),
            TestCase("prefix only counts as a whole word: favicon / :imgur stay keywords", testPrefixNeedsWordBoundary),
            TestCase("type chip keeps keyword and yields to colon prefix", testTypeChipResolving),
            TestCase("chinese substring search via trigram", testChineseSearch),
            TestCase("short keyword falls back to LIKE", testShortKeywordSearch),
            TestCase("search filters: kind and favorites", testSearchFilters),
            TestCase("search covers ocr text", testOCRSearchable),
            TestCase("pagination", testPagination),
        ]
    }

    static func testInsertAndList() throws {
        let store = try makeStore()
        let (item, inserted) = try store.upsertText("hello world")
        try expect(inserted)
        try expect(item.id > 0)
        let page = try store.search(SearchQuery())
        try expectEqual(page.total, 1)
        try expectEqual(page.items.first?.content, "hello world")
    }

    static func testTextDedupe() throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        _ = try store.upsertText("aaa", at: t0)
        _ = try store.upsertText("bbb", at: t0)
        let (_, inserted) = try store.upsertText("aaa", at: t1)
        try expect(!inserted, "duplicate text must not insert")
        let page = try store.search(SearchQuery())
        try expectEqual(page.total, 2)
        try expectEqual(page.items.first?.content, "aaa", "duplicate should move to front")
    }

    static func testSQLiteTextReads() throws {
        let db = try SQLiteDB(path: ":memory:")
        // 绕过 bind，独立覆盖两个读取方法，避免写入截断掩盖读取截断。
        let stmt = try db.prepare("SELECT CAST(X'61006200' AS TEXT), NULL, ''")
        try expect(try stmt.step())
        try expectEqual(stmt.columnText(0), "a\0b\0")
        try expectEqual(stmt.columnTextOrNil(0), "a\0b\0")
        try expectEqual(stmt.columnTextOrNil(1), nil)
        try expectEqual(stmt.columnTextOrNil(2), "")
        try expectEqual(stmt.columnText(1), "")
    }

    static func testEmbeddedNULText() throws {
        let store = try makeStore()
        let values = ["前缀", "前缀\0后缀🧪", "前缀\0不同后缀", "\0开头", "结尾\0", ""]
        for value in values {
            let (item, inserted) = try store.upsertText(value)
            try expect(inserted, "different text must not dedupe at NUL")
            try expectEqual(item.content, value)
            try expectEqual(try store.item(id: item.id)?.content, value)
            let (duplicate, reinserted) = try store.upsertText(value)
            try expect(!reinserted)
            try expectEqual(duplicate.id, item.id)
            try expectEqual(duplicate.content, value)
        }
        try expectEqual(try store.count(), values.count)
    }

    static func testImageDedupe() throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        let (_, inserted1) = try store.upsertImage(imagePath: "/tmp/a.png", thumbPath: "/tmp/ta.png", hash: "h1", at: t0)
        try expect(inserted1)
        let (item2, inserted2) = try store.upsertImage(imagePath: "/tmp/b.png", thumbPath: "/tmp/tb.png", hash: "h1", at: t1)
        try expect(!inserted2, "same hash must dedupe")
        try expectEqual(item2.imagePath, "/tmp/a.png", "keeps first-seen file")
        try expectEqual(try store.count(), 1)
    }

    static func testTruncation() throws {
        let store = try makeStore()
        let long = String(repeating: "x", count: 15000)
        let (item, _) = try store.upsertText(long)
        try expectEqual(item.content.count, 12000)
    }

    static func testFavoriteSurvivesPrune() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1000) // 远早于 24h 前
        let (item, _) = try store.upsertText("keep me", at: old)
        _ = try store.toggleFavorite(id: item.id)
        _ = try store.upsertText("old junk", at: old)
        let result = try store.prune(now: Date(timeIntervalSince1970: 200_000))
        try expectEqual(result.removedCount, 1)
        let page = try store.search(SearchQuery())
        try expectEqual(page.total, 1)
        try expectEqual(page.items.first?.content, "keep me")
    }

    static func testPastedSurvivesPrune() throws {
        var config = StoreConfig()
        config.hardLimit = 2
        config.favoritesPermanent = false
        let store = try ClipStore(config: config)
        let old = Date(timeIntervalSince1970: 1_000)
        let kept = try store.upsertText("used from app", at: old).item
        let image = try store.upsertImage(imagePath: "/tmp/kept.png", thumbPath: "/tmp/kept-small.png", hash: "kept", at: old).item
        let expired = try store.upsertText("copied only", at: old).item
        try store.markPasted(id: kept.id)
        try store.markPasted(id: image.id)
        _ = try store.prune(now: Date(timeIntervalSince1970: 200_000))
        try expect(try store.item(id: kept.id)?.wasPasted == true)
        try expect(try store.item(id: image.id)?.wasPasted == true)
        try expect(try store.item(id: expired.id) == nil)

        let now = Date(timeIntervalSince1970: 200_001)
        for i in 0..<5 { try store.upsertText("new \(i)", at: now.addingTimeInterval(Double(i))) }
        _ = try store.prune(now: now)
        try expect(try store.item(id: kept.id) != nil && store.item(id: image.id) != nil, "贴过的图/文都不占普通条数名额")
        try expectEqual(try store.count(), 4, "2 条永久保留 + 2 条普通历史")
    }

    static func testSourceFollowsLatestCopy() throws {
        let store = try makeStore()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        let third = Date(timeIntervalSince1970: 3_000)
        let (item, _) = try store.upsertText("same words", at: first)
        let pageA = BrowserSource(bundleID: "com.google.Chrome", title: "旧页", url: "https://example.com/docs-old")
        let pageB = BrowserSource(bundleID: "com.google.Chrome", title: "新页", url: "https://example.com/docs-new")
        try expect(try store.setBrowserSource(pageA, forItemID: item.id, copiedAt: first))
        try expectEqual(try store.search(SearchQuery(parsing: "docs-old")).total, 1, "可按来源 URL 找回记录")
        try store.markPasted(id: item.id)
        let repeated = try store.upsertText("same words", at: second)
        try expect(!repeated.inserted)
        try expect(repeated.item.browserSource == nil, "新复制没有 URL 时不能沿用旧页")
        try expect(repeated.item.wasPasted, "去重不取消永久保留")
        try expect(!store.setBrowserSource(pageA, forItemID: item.id, copiedAt: first), "异步旧页不能盖新页")
        try expect(try store.setBrowserSource(pageB, forItemID: item.id, copiedAt: second))
        try expectEqual(try store.item(id: item.id)?.browserSource, pageB)
        try expectEqual(try store.search(SearchQuery(parsing: "docs-old")).total, 0, "旧 URL 不应再能搜到")
        try expectEqual(try store.search(SearchQuery(parsing: "docs-new")).total, 1)
        try expectEqual(try store.search(SearchQuery(parsing: "新页")).total, 1, "两字标题走 LIKE")
        _ = try store.upsertText("same words", at: third)
        try expect(try store.item(id: item.id)?.browserSource == nil, "下次从非浏览器复制要清空来源")
        try expectEqual(try store.search(SearchQuery(parsing: "docs-new")).total, 0)
    }

    static func testApplyConfigAndPrune() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 200_000)
        let old = Date(timeIntervalSince1970: 1_000)

        let favoriteImage = try store.upsertImage(
            imagePath: "/tmp/expired.png", thumbPath: "/tmp/expired-small.png", hash: "expired", at: old
        ).item
        _ = try store.toggleFavorite(id: favoriteImage.id)
        let pasted = try store.upsertText("pasted survives policy change", at: old).item
        try store.markPasted(id: pasted.id)
        let olderRecent = try store.upsertText(
            "older recent", at: Date(timeIntervalSince1970: now.timeIntervalSince1970 - 120)
        ).item
        let newestRecent = try store.upsertText(
            "newest recent", at: Date(timeIntervalSince1970: now.timeIntervalSince1970 - 60)
        ).item

        let stricterConfig = StoreConfig(
            retentionSeconds: 3_600, hardLimit: 1, maxSaveLength: 12_000, favoritesPermanent: false
        )
        let result = try store.applyConfigAndPrune(stricterConfig, now: now)

        try expectEqual(result.removedCount, 2, "expired favorite plus the row beyond the new hard limit")
        try expectEqual(result.removedImageFiles.sorted(), ["/tmp/expired-small.png", "/tmp/expired.png"].sorted())
        try expect(try store.item(id: favoriteImage.id) == nil, "expired favorites follow the updated policy")
        try expect(try store.item(id: pasted.id)?.wasPasted == true, "pasted items remain exempt")
        try expect(try store.item(id: olderRecent.id) == nil, "the updated hard limit applies immediately")
        try expectEqual(try store.item(id: newestRecent.id)?.content, "newest recent")
        try expectEqual(try store.count(), 2)
    }

    static func testFavoritePrunedByAgeWhenNotPermanent() throws {
        var config = StoreConfig()
        config.favoritesPermanent = false
        let store = try ClipStore(config: config)
        let old = Date(timeIntervalSince1970: 1000) // 远早于 24h 前
        let (fav, _) = try store.upsertText("favorite old", at: old)
        _ = try store.toggleFavorite(id: fav.id)
        _ = try store.upsertText("plain old", at: old)
        let result = try store.prune(now: Date(timeIntervalSince1970: 200_000))
        try expectEqual(result.removedCount, 2, "favoritesPermanent=false should prune favorite by age too")
        try expectEqual(try store.count(), 0)
    }

    static func testFavoriteIncludedInHardLimitWhenNotPermanent() throws {
        var config = StoreConfig()
        config.hardLimit = 5
        config.favoritesPermanent = false
        let store = try ClipStore(config: config)
        let now = Date()
        for i in 0..<10 {
            let (item, _) = try store.upsertText("item \(i)", at: now.addingTimeInterval(TimeInterval(i)))
            if i == 0 { _ = try store.toggleFavorite(id: item.id) }
        }
        let result = try store.prune(now: now)
        try expectEqual(result.removedCount, 5)
        let page = try store.search(SearchQuery())
        try expectEqual(page.total, 5, "favoritesPermanent=false should count favorites toward hard limit")
        try expectEqual(page.items.first?.content, "item 9", "newest survives")
        try expectEqual(page.items.contains { $0.content == "item 0" }, false, "oldest favorite should be pruned")
    }

    static func testHardLimit() throws {
        var config = StoreConfig()
        config.hardLimit = 5
        let store = try ClipStore(config: config)
        let now = Date()
        for i in 0..<10 {
            _ = try store.upsertText("item \(i)", at: now.addingTimeInterval(TimeInterval(i)))
        }
        let result = try store.prune(now: now)
        try expectEqual(result.removedCount, 5)
        let page = try store.search(SearchQuery())
        try expectEqual(page.total, 5)
        try expectEqual(page.items.first?.content, "item 9", "newest survives")
    }

    static func testDelete() throws {
        let store = try makeStore()
        let (item, _) = try store.upsertImage(imagePath: "/tmp/a.png", thumbPath: "/tmp/ta.png", hash: "h1")
        let removed = try store.delete(id: item.id)
        try expectEqual(removed?.imagePath, "/tmp/a.png")
        try expectEqual(try store.count(), 0)
    }

    /// 老库升级：items 没有密钥列、FTS 没有 secret_name 列 → 打开时补列并重建 FTS。
    /// 守 FTS 建表语句（新建与迁移共用一份）不漂移。
    static func testLegacySchemaMigrates() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("jtb-legacy-\(UUID().uuidString).db").path
        do {
            let legacy = try SQLiteDB(path: path)
            try legacy.exec("""
            CREATE TABLE items (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, content TEXT NOT NULL,
                image_path TEXT, thumb_path TEXT, image_hash TEXT, ocr_text TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0, last_copied_at REAL NOT NULL, created_at REAL NOT NULL);
            CREATE VIRTUAL TABLE items_fts USING fts5(content, ocr_text, image_path,
                content = 'items', content_rowid = 'id', tokenize = 'trigram');
            CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, content, ocr_text, image_path) VALUES (new.id, new.content, new.ocr_text, new.image_path);
            END;
            INSERT INTO items(kind, content, last_copied_at, created_at) VALUES ('text', 'legacy 老数据 row', 1, 1);
            """)
        }
        let store = try ClipStore(path: path)
        try expectEqual(try store.search(SearchQuery(parsing: "老数据")).total, 1, "old rows are searchable after the FTS rebuild")
        let (item, _) = try store.upsertText("sk-" + String(repeating: "q", count: 40))
        try store.markAsSecret(id: item.id, encryptedContent: "jt://secret/x", token: "jt://secret/x",
                               type: nil, name: "生产库密码", maskedPreview: "sk••")
        try expectEqual(try store.search(SearchQuery(parsing: "生产库")).total, 1, "secret names are searchable (new FTS column)")
        try store.markSecretReferencesMissing(token: "jt://secret/x")
        try expect(try store.item(id: item.id)?.secretMissing == true, "secret_missing column added to old databases")
        let legacy = try unwrap(try store.search(SearchQuery(parsing: "老数据")).items.first)
        try expect(!legacy.wasPasted && legacy.browserSource == nil, "新字段不改变旧记录")
        let source = BrowserSource(bundleID: "com.google.Chrome", title: "旧库升级", url: "https://example.com/migrated-page")
        try store.setBrowserSource(source, forItemID: legacy.id, copiedAt: legacy.lastCopiedAt)
        let reopened = try ClipStore(path: path)
        try expectEqual(try reopened.search(SearchQuery(parsing: "migrated-page")).total, 1, "迁移后来源 URL 可持久搜索")
    }

    static func testQueryParsing() throws {
        try expectEqual(SearchQuery(parsing: ":img 截图").kindFilter, .image)
        try expectEqual(SearchQuery(parsing: ":i").kindFilter, .image)
        try expectEqual(SearchQuery(parsing: ":text hello").kindFilter, .text)
        try expect(SearchQuery(parsing: ":fav").favoritesOnly)
        try expect(SearchQuery(parsing: "fav 笔记").favoritesOnly)
        try expectEqual(SearchQuery(parsing: "fav 笔记").keyword, "笔记")
        try expectEqual(SearchQuery(parsing: "普通关键词").keyword, "普通关键词")
        try expectEqual(SearchQuery(parsing: ":img").keyword, "")
        try expectEqual(SearchQuery(parsing: ":secret").typeChip, .secret)
        try expectEqual(SearchQuery(parsing: ":s token").keyword, "token")
    }

    /// 回归：裸前缀后面没要求空格，搜 "favicon" 变成"只看收藏 + icon"，":imgur" 变成"只看图片 + ur"。
    static func testPrefixNeedsWordBoundary() throws {
        for raw in ["favicon", "favorite pizza", ":imgur", ":texture", ":something", ":iphone 15"] {
            let q = SearchQuery(parsing: raw)
            try expect(q.kindFilter == nil && !q.favoritesOnly && !q.secretsOnly, "\(raw) must not be read as a filter prefix")
            try expectEqual(q.keyword, raw)
        }
        try expectEqual(SearchQuery(parsing: "FAV 笔记").keyword, "笔记", "prefix is case-insensitive")
        try expectEqual(SearchQuery(parsing: ":i\t截图").kindFilter, .image, "any whitespace ends the prefix")
    }

    static func testTypeChipResolving() throws {
        try expectEqual(SearchTypeChip.allCases.map(\.title), ["全部", "文本", "图片", "收藏", "密钥"])

        let (fromPrefix, prefixChip) = SearchQuery.resolving(field: ":img 截图", chip: .all)
        try expectEqual(prefixChip, .image)
        try expectEqual(fromPrefix.kindFilter, .image)
        try expectEqual(fromPrefix.keyword, "截图")
        try expectEqual(fromPrefix.typeChip, .image)

        let (kept, keptChip) = SearchQuery.resolving(field: "截图", chip: .image)
        try expectEqual(keptChip, .image)
        try expectEqual(kept.kindFilter, .image)
        try expectEqual(kept.keyword, "截图")

        let (plain, plainChip) = SearchQuery.resolving(field: "hello", chip: .all)
        try expectEqual(plainChip, .all)
        try expect(plain.kindFilter == nil)
        try expectEqual(plain.keyword, "hello")

        let switched = SearchQuery(keyword: SearchQuery(parsing: ":img foo").keyword, chip: .text)
        try expectEqual(switched.keyword, "foo")
        try expectEqual(switched.kindFilter, .text)
        try expect(!switched.favoritesOnly)
        try expect(!switched.secretsOnly)

        let secret = SearchQuery(keyword: "abc", chip: .secret)
        try expect(secret.secretsOnly)
        try expectEqual(secret.keyword, "abc")
        try expectEqual(secret.typeChip, .secret)

        let (_, favChip) = SearchQuery.resolving(field: ":fav", chip: .all)
        try expectEqual(favChip, .favorite)
        let (_, secretChip) = SearchQuery.resolving(field: ":secret key", chip: .text)
        try expectEqual(secretChip, .secret)

        let (afterClear, afterChip) = SearchQuery.resolving(field: "", chip: .favorite)
        try expectEqual(afterChip, .favorite)
        try expect(afterClear.favoritesOnly)
        try expectEqual(afterClear.keyword, "")

        // 芯片路径不得把关键词里的 fav 再解析成前缀
        let literal = SearchQuery(keyword: "fav 笔记", chip: .all)
        try expect(!literal.favoritesOnly)
        try expectEqual(literal.keyword, "fav 笔记")
    }

    static func testChineseSearch() throws {
        let store = try makeStore()
        _ = try store.upsertText("今天中午吃什么好呢")
        _ = try store.upsertText("unrelated english text")
        let page = try store.search(SearchQuery(parsing: "吃什么"))
        try expectEqual(page.total, 1)
        try expectEqual(page.items.first?.content, "今天中午吃什么好呢")
    }

    static func testShortKeywordSearch() throws {
        let store = try makeStore()
        _ = try store.upsertText("ab cd")
        _ = try store.upsertText("xy zw")
        // 2 字符 < trigram 最小长度，走 LIKE 子串
        let page = try store.search(SearchQuery(parsing: "ab"))
        try expectEqual(page.total, 1)
        try expectEqual(page.items.first?.content, "ab cd")
    }

    static func testSearchFilters() throws {
        let store = try makeStore()
        _ = try store.upsertText("一段文本")
        let (img, _) = try store.upsertImage(imagePath: "/tmp/a.png", thumbPath: "/tmp/ta.png", hash: "h1")
        _ = try store.toggleFavorite(id: img.id)

        let imgOnly = try store.search(SearchQuery(parsing: ":img"))
        try expectEqual(imgOnly.total, 1)
        try expectEqual(imgOnly.items.first?.kind, .image)

        let textOnly = try store.search(SearchQuery(parsing: ":text"))
        try expectEqual(textOnly.total, 1)
        try expectEqual(textOnly.items.first?.kind, .text)

        let favOnly = try store.search(SearchQuery(parsing: ":fav"))
        try expectEqual(favOnly.total, 1)
        try expectEqual(favOnly.items.first?.kind, .image)

        let imgChip = try store.search(SearchQuery(keyword: "", chip: .image))
        try expectEqual(imgChip.total, imgOnly.total)
        try expectEqual(imgChip.items.first?.kind, .image)
    }

    static func testOCRSearchable() throws {
        let store = try makeStore()
        let (img, _) = try store.upsertImage(imagePath: "/tmp/a.png", thumbPath: "/tmp/ta.png", hash: "h1")
        try store.setOCRText("发票号码 123456", forItemID: img.id)
        let page = try store.search(SearchQuery(parsing: "发票号"))
        try expectEqual(page.total, 1)
        try expectEqual(page.items.first?.kind, .image)
    }

    static func testPagination() throws {
        let store = try makeStore()
        let now = Date()
        for i in 0..<100 {
            _ = try store.upsertText("row \(i)", at: now.addingTimeInterval(TimeInterval(i)))
        }
        let p1 = try store.search(SearchQuery(), page: 1, pageSize: 80)
        try expectEqual(p1.items.count, 80)
        try expectEqual(p1.total, 100)
        try expectEqual(p1.items.first?.content, "row 99")
        let p2 = try store.search(SearchQuery(), page: 2, pageSize: 80)
        try expectEqual(p2.items.count, 20)
        try expectEqual(p2.items.first?.content, "row 19")
    }
}
