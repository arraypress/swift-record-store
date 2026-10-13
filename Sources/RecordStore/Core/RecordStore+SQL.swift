//
//  RecordStore+SQL.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  The escape hatch: any SELECT, through a connection opened READ-ONLY. A
//  write is refused by SQLite itself, not by inspecting the text — so no
//  clever statement can slip one past.
//

import Foundation

public extension RecordStore {

    /// Runs one statement against a read-only connection to the file.
    ///
    /// Money columns come back as stored: integer minor units in the field's
    /// column and the currency in `<field>__currency`.
    static func readOnlySQL(_ sql: String, path: String) throws(RecordStoreError) -> ResultTable {
        guard FileManager.default.fileExists(atPath: path) else { throw .storage("no database at \(path)") }
        let db = try Database(path: path, readOnly: true)
        let rows = try db.query(sql)
        let columns = rows.first?.columns ?? []
        return ResultTable(columns: columns, rows: rows.map { row in
            var out: [String: JSONValue] = [:]
            for (name, value) in zip(row.columns, row.values) { out[name] = ValueCoercion.raw(value) }
            return out
        })
    }

    /// Runs one statement against this store's file, read-only.
    func readOnlySQL(_ sql: String) throws(RecordStoreError) -> ResultTable {
        try Self.readOnlySQL(sql, path: path)
    }
}
