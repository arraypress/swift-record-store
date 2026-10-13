//
//  RecordStore+Migrate.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Changing a collection's shape — only ever as an explicit step. Adding a
//  field is free; renaming keeps every value; dropping keeps a copy of the
//  dropped values in the journal so undo can put them back.
//

import Foundation

public extension RecordStore {

    /// Applies one change to a collection's schema.
    @discardableResult
    func migrate(_ collection: String, _ change: SchemaChange) throws(RecordStoreError) -> Schema {
        let before = try schema(named: collection)
        return try db.transaction { () throws(RecordStoreError) -> Schema in
            var after = before
            after.version += 1
            var undoValues: JSONValue = .null
            let summary: String
            let changeJSON: JSONValue

            switch change {
            case .addField(let proposed):
                let field = try SchemaRules.validated(proposed)
                guard !before.fields.contains(where: { $0.name == field.name }) else {
                    throw .invalidSchema("\(collection) already has a field \"\(field.name)\"")
                }
                let filled = field.default.map { $0 != .null } ?? false
                if field.required, !filled, try count(in: collection) > 0 {
                    throw .invalidSchema("\"\(field.name)\" is required but \(collection) already has records — give it a default")
                }
                for declaration in SchemaRules.declarations(of: field) {
                    try db.exec("ALTER TABLE \(SQLText.quoted(collection)) ADD COLUMN \(declaration)")
                }
                if let value = field.default, value != .null {
                    let columns = try coerced(value, field)
                    let names = SchemaRules.columns(of: field)
                    try db.run("UPDATE \(SQLText.quoted(collection)) SET \(names.map { "\(SQLText.quoted($0)) = ?" }.joined(separator: ", "))", columns)
                }
                if let index = SQLText.createIndex(field, in: collection) { try db.exec(index) }
                after.fields.append(field)
                summary = "added field \(field.name) (\(field.type.rawValue))"
                changeJSON = .object(["add": .string(field.name)])

            case .renameField(let from, let to):
                guard let index = before.fields.firstIndex(where: { $0.name == from }) else {
                    throw .unknownField(collection: collection, field: from)
                }
                guard SchemaRules.isIdentifier(to), to != "id" else { throw .invalidSchema("\"\(to)\" is not a usable field name") }
                guard !before.fields.contains(where: { $0.name == to }) else {
                    throw .invalidSchema("\(collection) already has a field \"\(to)\"")
                }
                var field = before.fields[index]
                try renameColumns(of: field, to: to, in: collection)
                field.name = to
                after.fields[index] = field
                summary = "renamed field \(from) to \(to)"
                changeJSON = .object(["rename": .string(from), "to": .string(to)])

            case .dropField(let name):
                guard let index = before.fields.firstIndex(where: { $0.name == name }) else {
                    throw .unknownField(collection: collection, field: name)
                }
                guard before.fields.count > 1 else { throw .invalidSchema("cannot drop the only field of \(collection)") }
                let field = before.fields[index]
                let names = SchemaRules.columns(of: field)
                // Keep the values so undo can restore them.
                var kept: [String: JSONValue] = [:]
                for row in try db.query("SELECT \"id\", \(names.map(SQLText.quoted).joined(separator: ", ")) FROM \(SQLText.quoted(collection))") {
                    guard case .int(let id) = row["id"] else { continue }
                    kept[String(id)] = .array(names.map { RowSnapshot.tagged(row[$0]) })
                }
                undoValues = .object(kept)
                try db.exec("DROP INDEX IF EXISTS \(SQLText.quoted(SQLText.indexName(name, in: collection)))")
                for column in names {
                    try db.exec("ALTER TABLE \(SQLText.quoted(collection)) DROP COLUMN \(SQLText.quoted(column))")
                }
                after.fields.remove(at: index)
                summary = "dropped field \(name) (\(kept.count) values kept for undo)"
                changeJSON = .object(["drop": .string(name)])
            }

            try saveSchema(after)
            let beforeJSON: JSONValue = .object(["schema": try JSONCoding.parse(JSONCoding.encode(before)), "values": undoValues])
            let afterJSON: JSONValue = .object(["schema": try JSONCoding.parse(JSONCoding.encode(after)), "change": changeJSON])
            try journal(collection, .migrate, recordID: nil, summary: summary,
                        before: JSONCoding.text(beforeJSON), after: JSONCoding.text(afterJSON))
            return after
        }
    }
}

extension RecordStore {

    func saveSchema(_ schema: Schema) throws(RecordStoreError) {
        try db.run("UPDATE \"_store_schemas\" SET \"definition\" = ?, \"updated_at\" = ? WHERE \"name\" = ?",
                   [.text(JSONCoding.encode(schema)), .text(timestamp()), .text(schema.name)])
    }

    func renameColumns(of field: Field, to newName: String, in collection: String) throws(RecordStoreError) {
        try db.exec("DROP INDEX IF EXISTS \(SQLText.quoted(SQLText.indexName(field.name, in: collection)))")
        var renamed = field
        renamed.name = newName
        for (old, new) in zip(SchemaRules.columns(of: field), SchemaRules.columns(of: renamed)) {
            try db.exec("ALTER TABLE \(SQLText.quoted(collection)) RENAME COLUMN \(SQLText.quoted(old)) TO \(SQLText.quoted(new))")
        }
        if let index = SQLText.createIndex(renamed, in: collection) { try db.exec(index) }
    }
}
