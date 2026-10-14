//
//  RecordStore+Links.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Keys and links. A collection with a key names its records by text
//  (`dairy`); a `ref`/`refs` field links to another collection's records and
//  stores their keys (or ids, when the target has no key). Links are checked
//  on every write in both directions: a value that names no record is
//  refused, and so is removing — or renaming — a record something links to.
//  `check` finds what slipped in some other way (an app writing the file
//  directly, a hand-edited row).
//

import Foundation

public extension RecordStore {

    /// Every problem in the database: links that name no record, keys that
    /// are missing or repeated, required fields left empty, and — for each
    /// collection in `requireLinked` — records nothing links to.
    func check(requireLinked: [String] = []) throws(RecordStoreError) -> [IntegrityProblem] {
        var problems: [IntegrityProblem] = []
        let all = try schemas()
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        for name in requireLinked where byName[name] == nil { throw .unknownCollection(name) }

        if let row = try db.query("PRAGMA quick_check").first, case .text(let result) = row.values.first ?? .null, result != "ok" {
            problems.append(IntegrityProblem(collection: "", record: "", field: nil, problem: "SQLite: \(result)"))
        }
        for schema in all {
            let rows = try db.query("SELECT * FROM \(SQLText.quoted(schema.name)) ORDER BY \"id\"")
            var seenKeys: [String: String] = [:]
            for row in rows {
                let record = label(row, schema)
                for field in schema.fields where field.required && row[field.name] == .null {
                    problems.append(IntegrityProblem(collection: schema.name, record: record, field: field.name, problem: "is required but empty"))
                }
                if let keyField = schema.keyField, case .text(let key) = row[keyField.name] {
                    if let problem = SchemaRules.keyProblem(key) {
                        problems.append(IntegrityProblem(collection: schema.name, record: record, field: keyField.name, problem: problem))
                    }
                    if let other = seenKeys[key.lowercased()] {
                        problems.append(IntegrityProblem(collection: schema.name, record: record, field: keyField.name,
                                                         problem: "repeats the key of \(other)"))
                    } else {
                        seenKeys[key.lowercased()] = "#\(id(of: row))"
                    }
                }
                for (field, value) in try danglingLinks(schema, row) {
                    problems.append(IntegrityProblem(collection: schema.name, record: record, field: field.name,
                                                     problem: "links to \(field.target ?? "?") \"\(value)\", which does not exist"))
                }
            }
        }
        for name in requireLinked {
            guard let schema = byName[name] else { continue }
            let sources = try referrers(of: schema.name)
            for row in try db.query("SELECT * FROM \(SQLText.quoted(schema.name)) ORDER BY \"id\"") {
                guard let identity = identity(row, schema) else { continue }
                if try linkers(of: identity, among: sources).isEmpty {
                    let from = sources.map { "\($0.schema.name).\($0.field.name)" }.joined(separator: ", ")
                    problems.append(IntegrityProblem(collection: schema.name, record: label(row, schema), field: nil,
                                                     problem: sources.isEmpty ? "nothing links to \(schema.name) at all"
                                                                              : "no record links to it (from \(from))"))
                }
            }
        }
        return problems
    }

    /// The id a reference names: `#12` is always an id; otherwise a key
    /// (matched without regard to case) when the collection has one, else a
    /// whole number as an id.
    func id(of reference: String, in collection: String) throws(RecordStoreError) -> Int64 {
        try resolve(reference, in: try schema(named: collection))
    }
}

extension RecordStore {

    // MARK: Naming records

    func resolve(_ reference: String, in schema: Schema) throws(RecordStoreError) -> Int64 {
        let text = reference.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#"), let id = Int64(text.dropFirst()) {
            guard try row(id, in: schema) != nil else { throw .recordNotFound(collection: schema.name, id: id) }
            return id
        }
        if let key = schema.key {
            if let match = try db.query("SELECT \"id\" FROM \(SQLText.quoted(schema.name)) WHERE lower(\(SQLText.quoted(key))) = lower(?) LIMIT 1",
                                        [.text(text)]).first, case .int(let id) = match["id"] {
                return id
            }
            guard let id = Int64(text) else { throw .keyNotFound(collection: schema.name, key: text) }
            guard try row(id, in: schema) != nil else { throw .recordNotFound(collection: schema.name, id: id) }
            return id
        }
        guard let id = Int64(text) else {
            throw .invalidQuery("\(schema.name) has no key, so its records are named by id — \"\(text)\" is not one")
        }
        guard try row(id, in: schema) != nil else { throw .recordNotFound(collection: schema.name, id: id) }
        return id
    }

    func id(of row: Database.Row) -> Int64 {
        if case .int(let id) = row["id"] { return id }
        return 0
    }

    /// The key of a row, or `#id`.
    func label(_ row: Database.Row, _ schema: Schema) -> String {
        if let key = schema.key, case .text(let text) = row[key] { return text }
        return "#\(id(of: row))"
    }

    /// What links to a row hold: its key, or its id when the collection has
    /// no key.
    func identity(_ row: Database.Row, _ schema: Schema) -> Database.Value? {
        if let key = schema.key {
            let value = row[key]
            return value == .null ? nil : value
        }
        return row["id"]
    }

    // MARK: Writing links

    /// A link field's value resolved against its target: keys in the
    /// target's own spelling, ids checked to exist.
    func linkColumns(_ value: JSONValue, _ field: Field) throws(RecordStoreError) -> [Database.Value] {
        if value == .null { return [.null] }
        guard let targetName = field.target else { throw .invalidSchema("\(field.name) links to nothing") }
        let target = try schema(named: targetName)
        let items: [JSONValue]
        do throws(CoercionFailure) {
            items = field.type == .ref ? [try single(value)] : try ValueCoercion.linkItems(value)
        } catch {
            throw .invalidValue(field: field.name, reason: error.reason)
        }
        var resolved: [Database.Value] = []
        var seen = Set<String>()
        for item in items {
            let canonical = try resolveLink(item, to: target, field: field)
            let text = ValueDisplay.text(ValueCoercion.raw(canonical)).lowercased()
            if seen.insert(text).inserted { resolved.append(canonical) }
        }
        if field.type == .ref { return [resolved.first ?? .null] }
        return [.text(JSONCoding.text(.array(resolved.map(ValueCoercion.raw))))]
    }

    private func single(_ value: JSONValue) throws(CoercionFailure) -> JSONValue {
        switch value {
        case .string(let s): return .string(s.trimmingCharacters(in: .whitespaces))
        case .number(let d) where DecimalMath.isWhole(d): return value
        case .array(let items) where items.count == 1: return try single(items[0])
        default: throw .reason("expected one key or id")
        }
    }

    /// One linked item: a key, an id, or `#id`.
    private func resolveLink(_ item: JSONValue, to target: Schema, field: Field) throws(RecordStoreError) -> Database.Value {
        var byID: Int64?
        var text = ""
        switch item {
        case .number(let d): byID = Int64(truncating: NSDecimalNumber(decimal: d))
        case .string(let s):
            text = s
            if s.hasPrefix("#") { byID = Int64(s.dropFirst()) }
            else if target.key == nil { byID = Int64(s) }
        default: break
        }
        let table = SQLText.quoted(target.name)
        if let byID {
            guard let row = try db.query("SELECT * FROM \(table) WHERE \"id\" = ?", [.int(byID)]).first else {
                throw .invalidValue(field: field.name, reason: "\(target.name) has no record #\(byID)")
            }
            return identity(row, target) ?? .int(byID)
        }
        guard let key = target.key else {
            throw .invalidValue(field: field.name, reason: "\(target.name) has no key, so a link names a record by id — \"\(text)\" is not one")
        }
        guard let row = try db.query("SELECT \(SQLText.quoted(key)) AS k FROM \(table) WHERE lower(\(SQLText.quoted(key))) = lower(?) LIMIT 1",
                                     [.text(text)]).first, case .text(let canonical) = row["k"] else {
            throw .invalidValue(field: field.name, reason: "\(target.name) has no \"\(text)\"")
        }
        return .text(canonical)
    }

    /// A link field's target must exist (or be the collection itself).
    func checkTarget(of field: Field, from schema: Schema) throws(RecordStoreError) {
        guard let target = field.target, target != schema.name else { return }
        guard try existingSchema(target) != nil else {
            throw .invalidSchema("\(field.name) links to \(target), which does not exist — define it first")
        }
    }

    // MARK: Who links to what

    /// Every link field, in any collection, that points at `collection`.
    func referrers(of collection: String) throws(RecordStoreError) -> [(schema: Schema, field: Field)] {
        try schemas().flatMap { schema in
            schema.fields.filter { $0.isLink && $0.target == collection }.map { (schema, $0) }
        }
    }

    /// The records (by link field) whose links hold `identity`.
    func linkers(of identity: Database.Value, among sources: [(schema: Schema, field: Field)]) throws(RecordStoreError) -> [(schema: Schema, field: Field, ids: [Int64])] {
        var out: [(Schema, Field, [Int64])] = []
        for (schema, field) in sources {
            let column = SQLText.quoted(field.name)
            let table = SQLText.quoted(schema.name)
            let match = identity.isText ? "lower(%@) = lower(?)" : "%@ = ?"
            let sql = field.type == .ref
                ? "SELECT \"id\" FROM \(table) WHERE " + match.replacingOccurrences(of: "%@", with: column)
                : "SELECT \"id\" FROM \(table) WHERE EXISTS (SELECT 1 FROM json_each(\(table).\(column)) AS \"je\" WHERE "
                    + match.replacingOccurrences(of: "%@", with: "\"je\".\"value\"") + ")"
            let ids = try db.query(sql + " ORDER BY \"id\"", [identity]).map { self.id(of: $0) }
            if !ids.isEmpty { out.append((schema, field, ids)) }
        }
        return out
    }

    /// The links of a row that name nothing: (field, the value as written).
    func danglingLinks(_ schema: Schema, _ row: Database.Row) throws(RecordStoreError) -> [(Field, String)] {
        var out: [(Field, String)] = []
        for field in schema.fields where field.isLink {
            guard let targetName = field.target else { continue }
            let target = try existingSchema(targetName)
            let values: [JSONValue]
            switch ValueCoercion.output(row, field: field) {
            case .null: continue
            case .array(let items): values = items
            case let one: values = [one]
            }
            for value in values {
                guard let target else { out.append((field, ValueDisplay.text(value))); continue }
                let column = SQLText.quoted(target.linkColumn)
                let bind: Database.Value
                switch value {
                case .number(let d): bind = .int(Int64(truncating: NSDecimalNumber(decimal: d)))
                default: bind = .text(ValueDisplay.text(value))
                }
                let found = try db.query("SELECT 1 FROM \(SQLText.quoted(target.name)) WHERE \(column) = ? LIMIT 1", [bind]).first != nil
                if !found { out.append((field, ValueDisplay.text(value))) }
            }
        }
        return out
    }

    /// The link rules for one record changing from `before` to `after`
    /// (nil for an insert or a delete): what it links to must exist, and
    /// what links to it must not be left pointing at nothing. With `force`
    /// (a delete), those links are taken out, journalled in the same batch.
    func enforceLinks(_ schema: Schema, before: Database.Row?, after: Database.Row?, force: Bool) throws(RecordStoreError) {
        if let after, let (field, value) = try danglingLinks(schema, after).first {
            throw .invalidValue(field: field.name, reason: "\(field.target ?? "?") has no \"\(value)\"")
        }
        guard let before, let old = identity(before, schema) else { return }
        if let after, let new = identity(after, schema), new == old { return }
        let found = try linkers(of: old, among: referrers(of: schema.name))
        guard !found.isEmpty else { return }
        let name = label(before, schema)
        let listed = found.map { "\($0.schema.name).\($0.field.name) (\($0.ids.count))" }.joined(separator: ", ")
        guard after == nil, force else {
            if after != nil {
                throw .linked("\(schema.name) \(name) is linked from \(listed) — its key cannot change while they point at it")
            }
            throw .linked("\(schema.name) \(name) is linked from \(listed) — remove those links first, or force to take them out")
        }
        for (source, field, ids) in found {
            if field.type == .ref, field.required {
                throw .linked("\(source.name).\(field.name) is required and \(ids.count) record\(ids.count == 1 ? "" : "s") point at \(name) — relink or delete \(ids.count == 1 ? "it" : "them") first")
            }
            let gone = ValueDisplay.text(ValueCoercion.raw(old))
            for id in ids {
                if field.type == .ref {
                    _ = try applyUpdate(id, in: source, with: [field.name: .null], adding: [:], removing: [:])
                } else {
                    _ = try applyUpdate(id, in: source, with: [:], adding: [:], removing: [field.name: [gone]])
                }
            }
        }
    }
}

private extension Database.Value {
    var isText: Bool { if case .text = self { true } else { false } }
}
