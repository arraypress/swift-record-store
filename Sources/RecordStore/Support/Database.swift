//
//  Database.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  The thinnest throwing wrapper over the system SQLite, the same shape as
//  swift-photo-index's: every C-API return code is checked once, here.
//  One difference matters: a database can be opened READ-ONLY, which is how
//  `sql` refuses writes — at the engine, not by inspecting the statement.
//

import Foundation
import SQLite3

/// `SQLITE_TRANSIENT`, which the Swift importer loses: tells sqlite to copy
/// bound text and blobs before the statement finalises.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One open SQLite database. Not shared across threads: one per caller.
final class Database {

    /// A value crossing into or out of a statement.
    enum Value: Equatable, Sendable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    /// One result row: column names and values, positionally.
    struct Row {
        let columns: [String]
        let values: [Value]

        subscript(_ name: String) -> Value {
            guard let index = columns.firstIndex(of: name) else { return .null }
            return values[index]
        }
    }

    private var handle: OpaquePointer?

    /// Whether writes are refused by the engine.
    let readOnly: Bool

    init(path: String, readOnly: Bool = false) throws(RecordStoreError) {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw .storage("\(message) (\(path))")
        }
        handle = db
        self.readOnly = readOnly
        sqlite3_busy_timeout(db, 5_000)
        if readOnly {
            // Belt and braces: query_only also refuses writes to an attached
            // or temp database that the open flags alone would allow.
            try exec("PRAGMA query_only = 1")
        } else {
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA foreign_keys = ON")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs statements that take no bindings and return no rows.
    func exec(_ sql: String) throws(RecordStoreError) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw classify(message, sql: sql)
        }
    }

    /// Runs one bound statement, discarding any rows.
    func run(_ sql: String, _ binds: [Value] = []) throws(RecordStoreError) {
        _ = try query(sql, binds)
    }

    /// Runs one bound statement and returns its rows.
    func query(_ sql: String, _ binds: [Value] = []) throws(RecordStoreError) -> [Row] {
        var statement: OpaquePointer?
        var trailing = ""
        let prepared = sql.withCString { text -> Int32 in
            var tail: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(handle, text, -1, &statement, &tail)
            if let tail { trailing = String(cString: tail) }
            return code
        }
        guard prepared == SQLITE_OK else {
            throw classify(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        // One statement per call: anything after the first would otherwise be
        // silently ignored — and a caller should never wonder which ran.
        guard trailing.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))).isEmpty else {
            throw .invalidQuery("one statement at a time — found more after the first")
        }

        for (position, value) in binds.enumerated() {
            let slot = Int32(position + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, slot)
            case .int(let v): code = sqlite3_bind_int64(statement, slot, v)
            case .real(let v): code = sqlite3_bind_double(statement, slot, v)
            case .text(let v): code = sqlite3_bind_text(statement, slot, v, -1, transient)
            case .blob(let v):
                code = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, slot, bytes.baseAddress, Int32(bytes.count), transient)
                }
            }
            guard code == SQLITE_OK else {
                throw .storage("bind \(slot) failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
        }

        let count = Int(sqlite3_column_count(statement))
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw classify(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
            var values: [Value] = []
            values.reserveCapacity(count)
            for column in 0..<count {
                let c = Int32(column)
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(statement, c)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(statement, c)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(statement, c))))
                case SQLITE_BLOB:
                    if let base = sqlite3_column_blob(statement, c) {
                        values.append(.blob(Data(bytes: base, count: Int(sqlite3_column_bytes(statement, c)))))
                    } else {
                        values.append(.blob(Data()))
                    }
                default: values.append(.null)
                }
            }
            rows.append(Row(columns: columns, values: values))
        }
        return rows
    }

    /// The rowid of the most recent insert.
    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` in one transaction: everything or nothing.
    func transaction<T>(_ body: () throws(RecordStoreError) -> T) throws(RecordStoreError) -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Turns an SQLite message into the error a caller can act on.
    private func classify(_ message: String, sql: String) -> RecordStoreError {
        if message.contains("readonly") || message.contains("read-only") || message.contains("query_only") {
            return .readOnly("this connection is read-only: \(message)")
        }
        if message.hasPrefix("UNIQUE constraint failed") {
            return .duplicate(message)
        }
        return .storage("\(message) — in: \(sql.prefix(160))")
    }
}
