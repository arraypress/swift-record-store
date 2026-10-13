//
//  RecordStore+Journal.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Every write is journalled with exact snapshots, and undo reverses one —
//  but only after proving the target is still in the state the entry left
//  it in. An update that was itself overwritten is not silently clobbered;
//  an undone entry is marked and can never be applied twice.
//

import Foundation

public extension RecordStore {

    /// Recent writes, newest first.
    func history(limit: Int = 20, collection: String? = nil) throws(RecordStoreError) -> [JournalEntry] {
        var sql = "SELECT * FROM \"_store_journal\""
        var binds: [Database.Value] = []
        if let collection { sql += " WHERE \"collection\" = ?"; binds.append(.text(collection)) }
        sql += " ORDER BY \"id\" DESC LIMIT \(max(1, limit))"
        return try db.query(sql, binds).map(entry(from:))
    }

    /// Reverses one write: by default the newest one not yet undone.
    @discardableResult
    func undo(entry entryID: Int64? = nil) throws(RecordStoreError) -> JournalEntry {
        return try db.transaction { () throws(RecordStoreError) -> JournalEntry in
            let rows: [Database.Row]
            if let entryID {
                rows = try db.query("SELECT * FROM \"_store_journal\" WHERE \"id\" = ?", [.int(entryID)])
            } else {
                rows = try db.query("SELECT * FROM \"_store_journal\" WHERE \"undone\" = 0 ORDER BY \"id\" DESC LIMIT 1")
            }
            guard let row = rows.first else {
                throw .cannotUndo(entryID.map { "there is no journal entry #\($0)" } ?? "nothing to undo")
            }
            let target = entry(from: row)
            guard !target.undone else { throw .cannotUndo("entry #\(target.id) was already undone") }
            let before = text(row["before"]), after = text(row["after"])

            switch target.action {
            case .insert:
                let schema = try schema(named: target.collection)
                guard let id = target.recordID, let current = try self.row(id, in: schema) else {
                    throw .cannotUndo("record #\(target.recordID ?? 0) is already gone")
                }
                guard try matches(current, after) else { throw .cannotUndo("record #\(id) has changed since it was added — undo the later change first") }
                try db.run("DELETE FROM \(SQLText.quoted(schema.name)) WHERE \"id\" = ?", [.int(id)])

            case .update:
                let schema = try schema(named: target.collection)
                guard let id = target.recordID, let current = try self.row(id, in: schema) else {
                    throw .cannotUndo("record #\(target.recordID ?? 0) no longer exists")
                }
                guard try matches(current, after) else { throw .cannotUndo("record #\(id) has changed since — undo the later change first") }
                let values = try RowSnapshot.values(before ?? "{}").filter { $0.key != "id" }
                let names = values.keys.sorted()
                try db.run("UPDATE \(SQLText.quoted(schema.name)) SET \(names.map { "\(SQLText.quoted($0)) = ?" }.joined(separator: ", ")) WHERE \"id\" = ?",
                           names.map { values[$0]! } + [.int(id)])

            case .delete:
                let schema = try schema(named: target.collection)
                guard let id = target.recordID else { throw .cannotUndo("entry has no record") }
                guard try self.row(id, in: schema) == nil else { throw .cannotUndo("record #\(id) exists again") }
                let values = try RowSnapshot.values(before ?? "{}")
                let names = values.keys.sorted()
                try db.run("INSERT INTO \(SQLText.quoted(schema.name)) (\(names.map(SQLText.quoted).joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                           names.map { values[$0]! })

            case .define:
                let schema = try schema(named: target.collection)
                guard try count(in: schema.name) == 0 else {
                    throw .cannotUndo("\(schema.name) has records — delete them first, then undo the definition")
                }
                try db.exec("DROP TABLE \(SQLText.quoted(schema.name))")
                try db.run("DELETE FROM \"_store_schemas\" WHERE \"name\" = ?", [.text(schema.name)])

            case .migrate:
                try undoMigration(target, before: before, after: after)
            }

            try db.run("UPDATE \"_store_journal\" SET \"undone\" = 1 WHERE \"id\" = ?", [.int(target.id)])
            var done = target
            done.undone = true
            return done
        }
    }
}

extension RecordStore {

    func entry(from row: Database.Row) -> JournalEntry {
        var id: Int64 = 0, record: Int64?, undone = false
        if case .int(let i) = row["id"] { id = i }
        if case .int(let r) = row["record_id"] { record = r }
        if case .int(let u) = row["undone"] { undone = u != 0 }
        return JournalEntry(id: id, at: text(row["at"]) ?? "", collection: text(row["collection"]) ?? "",
                            action: JournalAction(rawValue: text(row["action"]) ?? "") ?? .insert,
                            recordID: record, summary: text(row["summary"]) ?? "", undone: undone)
    }

    private func text(_ value: Database.Value) -> String? {
        if case .text(let s) = value { return s }
        return nil
    }

    /// Whether a live row is exactly what a snapshot recorded.
    private func matches(_ row: Database.Row, _ snapshot: String?) throws(RecordStoreError) -> Bool {
        guard let snapshot else { return false }
        let recorded = try RowSnapshot.values(snapshot)
        for (name, value) in zip(row.columns, row.values) where recorded[name] ?? .null != value {
            return false
        }
        return true
    }

    private func undoMigration(_ entry: JournalEntry, before: String?, after: String?) throws(RecordStoreError) {
        guard let before, let after,
              case .object(let beforeObject) = try JSONCoding.parse(before),
              case .object(let afterObject) = try JSONCoding.parse(after),
              let beforeSchemaValue = beforeObject["schema"], let afterSchemaValue = afterObject["schema"],
              case .object(let change)? = afterObject["change"] else {
            throw .cannotUndo("the journal entry is incomplete")
        }
        let oldSchema = try JSONCoding.decode(Schema.self, from: JSONCoding.text(beforeSchemaValue))
        let newSchema = try JSONCoding.decode(Schema.self, from: JSONCoding.text(afterSchemaValue))
        let current = try schema(named: entry.collection)
        guard current == newSchema else { throw .cannotUndo("\(entry.collection) has changed shape since — undo the later change first") }
        let table = SQLText.quoted(entry.collection)

        if case .string(let added)? = change["add"], let field = newSchema.fields.first(where: { $0.name == added }) {
            try db.exec("DROP INDEX IF EXISTS \(SQLText.quoted(SQLText.indexName(added, in: entry.collection)))")
            for column in SchemaRules.columns(of: field) {
                try db.exec("ALTER TABLE \(table) DROP COLUMN \(SQLText.quoted(column))")
            }
        } else if case .string(let from)? = change["rename"], case .string(let to)? = change["to"],
                  let field = newSchema.fields.first(where: { $0.name == to }) {
            try renameColumns(of: field, to: from, in: entry.collection)
        } else if case .string(let dropped)? = change["drop"], let field = oldSchema.fields.first(where: { $0.name == dropped }) {
            for declaration in SchemaRules.declarations(of: field) {
                try db.exec("ALTER TABLE \(table) ADD COLUMN \(declaration)")
            }
            let names = SchemaRules.columns(of: field)
            if case .object(let kept)? = beforeObject["values"] {
                for (id, cells) in kept {
                    guard let rowID = Int64(id), case .array(let tagged) = cells else { continue }
                    try db.run("UPDATE \(table) SET \(names.map { "\(SQLText.quoted($0)) = ?" }.joined(separator: ", ")) WHERE \"id\" = ?",
                               tagged.map(RowSnapshot.untagged) + [.int(rowID)])
                }
            }
            if let index = SQLText.createIndex(field, in: entry.collection) { try db.exec(index) }
        } else {
            throw .cannotUndo("unrecognised migration")
        }
        try saveSchema(oldSchema)
    }
}
