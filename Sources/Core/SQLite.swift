import Foundation
import SQLite3

/// 系统 libsqlite3 的最薄封装：只提供 prepare/bind/step，不发明 ORM。
/// 所有调用必须在同一线程（本项目中为 main actor）串行进行。

public struct SQLiteError: Error, CustomStringConvertible, LocalizedError {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
    public var errorDescription: String? { "数据库出错：\(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDB {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    private func error(_ rc: Int32, context: String) -> SQLiteError {
        let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return SQLiteError(code: rc, message: "\(context): \(msg)")
    }

    /// 执行不返回行的 SQL（可多条，分号分隔）
    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStmt {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, context: "prepare") }
        return SQLiteStmt(db: self, stmt: stmt)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    fileprivate func checkOK(_ rc: Int32, context: String) throws {
        guard rc == SQLITE_OK else { throw error(rc, context: context) }
    }
}

public final class SQLiteStmt {
    private let db: SQLiteDB
    private let stmt: OpaquePointer

    fileprivate init(db: SQLiteDB, stmt: OpaquePointer) {
        self.db = db
        self.stmt = stmt
    }

    deinit { sqlite3_finalize(stmt) }

    public func bind(_ index: Int32, _ value: String) throws {
        try db.checkOK(sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT), context: "bind text")
    }

    public func bind(_ index: Int32, _ value: String?) throws {
        if let value { try bind(index, value) } else { try bindNull(index) }
    }

    public func bind(_ index: Int32, _ value: Int64) throws {
        try db.checkOK(sqlite3_bind_int64(stmt, index, value), context: "bind int64")
    }

    public func bind(_ index: Int32, _ value: Double) throws {
        try db.checkOK(sqlite3_bind_double(stmt, index, value), context: "bind double")
    }

    public func bindNull(_ index: Int32) throws {
        try db.checkOK(sqlite3_bind_null(stmt, index), context: "bind null")
    }

    /// 返回 true 表示有一行可读，false 表示 DONE
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        try db.checkOK(rc, context: "step")
        return false // 不可达：checkOK 对非 OK 必抛错
    }

    public func columnText(_ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    public func columnTextOrNil(_ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    public func columnInt64(_ index: Int32) -> Int64 { sqlite3_column_int64(stmt, index) }

    public func columnDouble(_ index: Int32) -> Double { sqlite3_column_double(stmt, index) }
}
