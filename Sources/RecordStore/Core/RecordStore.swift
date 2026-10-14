//
//  RecordStore.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A local database whose shapes are defined at run time. A schema — fields
//  with types — becomes a real SQLite table; records are checked against it
//  on the way in, so the table only ever holds values that fit; and every
//  write is journalled so it can be undone.
//
//  The store's own bookkeeping lives in two tables: `_store_schemas` (each
//  collection's definition, as JSON) and `_store_journal` (every write, with
//  exact before/after snapshots). Collections never start with an
//  underscore, so the two can never collide.
//

import CryptoKit
import Foundation

/// One database file of schema-checked collections.
///
/// Not thread-safe: open one per caller.
public final class RecordStore {

    /// The database file.
    public let path: String

    let db: Database

    /// What "now" is, for timestamps and relative dates. Injectable for tests.
    public var now: () -> Date = Date.init

    /// The zone dates without an offset are read in.
    public var timeZone: TimeZone = .current

    /// Opens (or creates) a store.
    public init(path: String) throws(RecordStoreError) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw .storage("cannot create \(directory): \(error.localizedDescription)")
            }
        }
        db = try Database(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS "_store_schemas" (
                "name" TEXT PRIMARY KEY, "definition" TEXT NOT NULL,
                "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS "_store_journal" (
                "id" INTEGER PRIMARY KEY AUTOINCREMENT, "at" TEXT NOT NULL,
                "collection" TEXT NOT NULL, "action" TEXT NOT NULL, "record_id" INTEGER,
                "summary" TEXT NOT NULL, "before" TEXT, "after" TEXT,
                "undone" INTEGER NOT NULL DEFAULT 0);
            """)
    }

    // MARK: Schemas

    /// Creates a collection.
    @discardableResult
    public func define(_ schema: Schema) throws(RecordStoreError) -> Schema {
        var schema = try SchemaRules.validated(schema)
        schema.version = 1
        if try existingSchema(schema.name) != nil {
            throw .invalidSchema("\(schema.name) already exists — change it with migrate")
        }
        let stamp = timestamp()
        try db.transaction { () throws(RecordStoreError) in
            try db.exec(SQLText.createTable(schema))
            for index in SQLText.createIndexes(schema) { try db.exec(index) }
            try db.run("INSERT INTO \"_store_schemas\" VALUES (?, ?, ?, ?)",
                       [.text(schema.name), .text(JSONCoding.encode(schema)), .text(stamp), .text(stamp)])
            try journal(schema.name, .define, recordID: nil,
                        summary: "defined \(schema.name) (\(schema.fields.count) fields)",
                        before: nil, after: JSONCoding.encode(schema))
        }
        return schema
    }

    /// Every collection's schema, by name.
    public func schemas() throws(RecordStoreError) -> [Schema] {
        var out: [Schema] = []
        for row in try db.query("SELECT \"definition\" FROM \"_store_schemas\" ORDER BY \"name\"") {
            guard case .text(let text) = row["definition"] else { continue }
            out.append(try JSONCoding.decode(Schema.self, from: text))
        }
        return out
    }

    /// One collection's schema.
    public func schema(named name: String) throws(RecordStoreError) -> Schema {
        guard let schema = try existingSchema(name) else { throw .unknownCollection(name) }
        return schema
    }

    /// How many records a collection holds.
    public func count(in collection: String) throws(RecordStoreError) -> Int {
        let schema = try schema(named: collection)
        guard case .int(let n) = try db.query("SELECT COUNT(*) AS n FROM \(SQLText.quoted(schema.name))").first?["n"] else { return 0 }
        return Int(n)
    }

    // MARK: Records

    /// Adds one record.
    @discardableResult
    public func add(_ values: [String: JSONValue], to collection: String, provenance: Provenance = Provenance(),
                    allowDuplicate: Bool = false) throws(RecordStoreError) -> Record {
        let schema = try schema(named: collection)
        return try db.transaction { () throws(RecordStoreError) -> Record in
            try insert(values, into: schema, provenance: provenance, checkSource: !allowDuplicate)
        }
    }

    /// Adds many records in one transaction: all of them, or — if any does
    /// not fit — none, with every problem listed.
    @discardableResult
    public func addAll(_ batch: [(line: Int, value: [String: JSONValue])], to collection: String,
                       provenance: Provenance = Provenance(), allowDuplicate: Bool = false) throws(RecordStoreError) -> [Record] {
        let schema = try schema(named: collection)
        return try db.transaction { () throws(RecordStoreError) -> [Record] in
            // Every record of a batch shares its source, so the source is
            // checked once — the batch is the duplicate, not its second row.
            if !allowDuplicate { try checkSource(provenance, in: schema) }
            var added: [Record] = []
            var problems: [String] = []
            for (line, values) in batch {
                do throws(RecordStoreError) {
                    added.append(try insert(values, into: schema, provenance: provenance, checkSource: false))
                } catch {
                    problems.append("record \(line): \(error.message)")
                    if problems.count >= 25 { problems.append("… and possibly more"); break }
                }
            }
            if !problems.isEmpty { throw .invalidRecords(problems) }
            return added
        }
    }

    /// One record by id.
    public func get(_ id: Int64, from collection: String) throws(RecordStoreError) -> Record {
        let schema = try schema(named: collection)
        guard let row = try row(id, in: schema) else { throw .recordNotFound(collection: collection, id: id) }
        return record(from: row, schema: schema)
    }

    /// Changes some fields of a record. A field set to null is cleared,
    /// unless it is required.
    @discardableResult
    public func update(_ id: Int64, in collection: String, with values: [String: JSONValue]) throws(RecordStoreError) -> Record {
        try update(id, in: collection, with: values, adding: [:], removing: [:])
    }

    /// Changes some fields of a record, and adds or removes tags without
    /// restating the rest: `adding: ["symptoms": ["stomach pain"]]` keeps the
    /// symptoms already there. Read and written in one transaction, so the
    /// journal's before and after are the whole change.
    public func update(_ id: Int64, in collection: String, with values: [String: JSONValue],
                       adding: [String: [String]], removing: [String: [String]]) throws(RecordStoreError) -> Record {
        let schema = try schema(named: collection)
        return try db.transaction { () throws(RecordStoreError) -> Record in
            guard let before = try row(id, in: schema) else { throw .recordNotFound(collection: collection, id: id) }
            var values = values
            let current = record(from: before, schema: schema).values
            for name in Set(adding.keys).union(removing.keys).sorted() {
                guard let field = schema.fields.first(where: { $0.name == name }) else {
                    throw .unknownField(collection: schema.name, field: name)
                }
                guard field.type == .tags else { throw .invalidValue(field: name, reason: "is \(field.type.rawValue) — only tags are added to or removed from") }
                guard values[name] == nil else { throw .invalidValue(field: name, reason: "is both set and added to; do one") }
                let have: [String] = if case .array(let items) = current[name] ?? .null {
                    items.compactMap { if case .string(let s) = $0 { s } else { nil } }
                } else { [] }
                values[name] = .array(TagEdits.applied(have, adding: adding[name] ?? [], removing: removing[name] ?? []).map(JSONValue.string))
            }
            try rejectUnknown(values.keys, in: schema)
            guard !values.isEmpty else { throw .invalidValue(field: "", reason: "nothing to change") }
            var sets: [String] = []
            var binds: [Database.Value] = []
            for field in schema.fields {
                guard let value = values[field.name] else { continue }
                if value == .null && field.required { throw .invalidValue(field: field.name, reason: "is required") }
                let columns = try coerced(value, field)
                if field.unique, value != .null { try checkUnique(field, columns, in: schema, excluding: id) }
                for (name, column) in zip(SchemaRules.columns(of: field), columns) {
                    sets.append("\(SQLText.quoted(name)) = ?")
                    binds.append(column)
                }
            }
            sets.append("\"_updated_at\" = ?")
            binds.append(.text(timestamp()))
            try db.run("UPDATE \(SQLText.quoted(schema.name)) SET \(sets.joined(separator: ", ")) WHERE \"id\" = ?", binds + [.int(id)])
            guard let after = try row(id, in: schema) else { throw .recordNotFound(collection: collection, id: id) }
            try journal(schema.name, .update, recordID: id,
                        summary: "updated #\(id) (\(values.keys.sorted().joined(separator: ", ")))",
                        before: RowSnapshot.text(before), after: RowSnapshot.text(after))
            return record(from: after, schema: schema)
        }
    }

    /// Removes a record. Undo puts it back with the same id.
    @discardableResult
    public func delete(_ id: Int64, from collection: String) throws(RecordStoreError) -> Record {
        let schema = try schema(named: collection)
        return try db.transaction { () throws(RecordStoreError) -> Record in
            guard let before = try row(id, in: schema) else { throw .recordNotFound(collection: collection, id: id) }
            try db.run("DELETE FROM \(SQLText.quoted(schema.name)) WHERE \"id\" = ?", [.int(id)])
            try journal(schema.name, .delete, recordID: id, summary: "deleted #\(id)",
                        before: RowSnapshot.text(before), after: nil)
            return record(from: before, schema: schema)
        }
    }

    // MARK: Internals shared with the extensions

    func existingSchema(_ name: String) throws(RecordStoreError) -> Schema? {
        guard let row = try db.query("SELECT \"definition\" FROM \"_store_schemas\" WHERE \"name\" = ?", [.text(name)]).first,
              case .text(let text) = row["definition"] else { return nil }
        return try JSONCoding.decode(Schema.self, from: text)
    }

    func row(_ id: Int64, in schema: Schema) throws(RecordStoreError) -> Database.Row? {
        try db.query("SELECT * FROM \(SQLText.quoted(schema.name)) WHERE \"id\" = ?", [.int(id)]).first
    }

    func record(from row: Database.Row, schema: Schema) -> Record {
        var values: [String: JSONValue] = [:]
        for field in schema.fields { values[field.name] = ValueCoercion.output(row, field: field) }
        func text(_ column: String) -> String? {
            if case .text(let s) = row[column] { return s }
            return nil
        }
        let id: Int64
        if case .int(let i) = row["id"] { id = i } else { id = 0 }
        return Record(id: id, values: values,
                      provenance: Provenance(source: text("_source"), sourceSHA256: text("_source_sha256"), tool: text("_tool")),
                      addedAt: text("_added_at") ?? "", updatedAt: text("_updated_at"))
    }

    func timestamp() -> String { DateParsing.utc(now()) }

    func journal(_ collection: String, _ action: JournalAction, recordID: Int64?, summary: String,
                 before: String?, after: String?) throws(RecordStoreError) {
        try db.run("""
            INSERT INTO "_store_journal" ("at", "collection", "action", "record_id", "summary", "before", "after")
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(timestamp()), .text(collection), .text(action.rawValue), recordID.map(Database.Value.int) ?? .null,
                  .text(summary), before.map(Database.Value.text) ?? .null, after.map(Database.Value.text) ?? .null])
    }

    func coerced(_ value: JSONValue, _ field: Field) throws(RecordStoreError) -> [Database.Value] {
        do throws(CoercionFailure) {
            return try ValueCoercion.columns(for: value, field: field, now: now(), timeZone: timeZone)
        } catch {
            throw .invalidValue(field: field.name, reason: error.reason)
        }
    }

    func rejectUnknown(_ keys: some Sequence<String>, in schema: Schema) throws(RecordStoreError) {
        let known = Set(schema.fields.map(\.name))
        for key in keys where !known.contains(key) {
            throw .unknownField(collection: schema.name, field: key)
        }
    }

    // MARK: Private

    private func checkSource(_ provenance: Provenance, in schema: Schema) throws(RecordStoreError) {
        guard let hash = provenance.sourceSHA256,
              let existing = try db.query("SELECT \"id\" FROM \(SQLText.quoted(schema.name)) WHERE \"_source_sha256\" = ? LIMIT 1", [.text(hash)]).first else { return }
        var where_ = ""
        if case .int(let id) = existing["id"] { where_ = " as #\(id)" }
        throw .duplicate("this source was already added\(where_) — pass allow-duplicate to add it again")
    }

    private func insert(_ values: [String: JSONValue], into schema: Schema, provenance: Provenance,
                        checkSource: Bool) throws(RecordStoreError) -> Record {
        try rejectUnknown(values.keys, in: schema)
        if checkSource { try self.checkSource(provenance, in: schema) }
        var names: [String] = []
        var binds: [Database.Value] = []
        for field in schema.fields {
            var value = values[field.name] ?? .null
            if value == .null, let fallback = field.default { value = fallback }
            if value == .null && field.required { throw .invalidValue(field: field.name, reason: "is required") }
            let columns = try coerced(value, field)
            if field.unique, value != .null { try checkUnique(field, columns, in: schema, excluding: nil) }
            names += SchemaRules.columns(of: field)
            binds += columns
        }
        names += ["_source", "_source_sha256", "_tool", "_added_at"]
        binds += [provenance.source.map(Database.Value.text) ?? .null, provenance.sourceSHA256.map(Database.Value.text) ?? .null,
                  provenance.tool.map(Database.Value.text) ?? .null, .text(timestamp())]
        try db.run("INSERT INTO \(SQLText.quoted(schema.name)) (\(names.map(SQLText.quoted).joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))", binds)
        let id = db.lastInsertID
        guard let after = try row(id, in: schema) else { throw .storage("the insert did not stick") }
        try journal(schema.name, .insert, recordID: id, summary: "added #\(id)", before: nil, after: RowSnapshot.text(after))
        return record(from: after, schema: schema)
    }

    private func checkUnique(_ field: Field, _ columns: [Database.Value], in schema: Schema, excluding id: Int64?) throws(RecordStoreError) {
        let names = SchemaRules.columns(of: field)
        var sql = "SELECT \"id\" FROM \(SQLText.quoted(schema.name)) WHERE " + names.map { "\(SQLText.quoted($0)) = ?" }.joined(separator: " AND ")
        var binds = columns
        if let id { sql += " AND \"id\" != ?"; binds.append(.int(id)) }
        if let match = try db.query(sql + " LIMIT 1", binds).first, case .int(let other) = match["id"] {
            throw .duplicate("\(field.name) must be unique and #\(other) already has that value")
        }
    }
}

/// SHA-256 of a file, hex — the duplicate key for records read from it.
public func sha256Hex(ofFileAt path: String) throws(RecordStoreError) -> String {
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) } catch {
        throw .storage("cannot read \(path): \(error.localizedDescription)")
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
