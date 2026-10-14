//
//  RecordStore+Migrate.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Changing a collection's shape — only ever as an explicit step. Adding a
//  field is free; renaming keeps every value; dropping keeps a copy of the
//  dropped values in the journal so undo can put them back. Setting a key is
//  how a collection made before keys existed starts naming its records by
//  text: every record must already have a distinct one.
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
                if field.isLink { try checkTarget(of: field, from: before) }
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
                if before.key == from { after.key = to }
                summary = "renamed field \(from) to \(to)"
                changeJSON = .object(["rename": .string(from), "to": .string(to)])

            case .dropField(let name):
                guard let index = before.fields.firstIndex(where: { $0.name == name }) else {
                    throw .unknownField(collection: collection, field: name)
                }
                guard before.fields.count > 1 else { throw .invalidSchema("cannot drop the only field of \(collection)") }
                let field = before.fields[index]
                if before.key == name {
                    let linking = try referrers(of: collection)
                    guard linking.isEmpty else {
                        throw .linked("\(name) is the key of \(collection) and \(linking.map { "\($0.schema.name).\($0.field.name)" }.joined(separator: ", ")) link by it — drop those first")
                    }
                    after.key = nil
                }
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

            case .setKey(let name):
                try setKey(name, before: before, after: &after)
                summary = name.map { "made \($0) the key" } ?? "stopped naming records by key"
                changeJSON = .object(["key": name.map(JSONValue.string) ?? .null])

            case .saveReport(let report):
                guard let reportName = report.name else { throw .invalidSchema("a saved report needs a name") }
                var reports = (before.reports ?? []).filter { $0.name != reportName }
                reports.append(report)
                after.reports = reports.sorted { ($0.name ?? "") < ($1.name ?? "") }
                after = try SchemaRules.validated(after)
                try checkReport(report, in: after)
                summary = "saved report \(reportName)"
                changeJSON = .object(["report": .string(reportName)])

            case .removeReport(let reportName):
                guard before.reports?.contains(where: { $0.name == reportName }) == true else {
                    throw .invalidQuery("\(collection) has no saved report \"\(reportName)\"")
                }
                after.reports = before.reports?.filter { $0.name != reportName }
                if after.reports?.isEmpty == true { after.reports = nil }
                summary = "removed report \(reportName)"
                changeJSON = .object(["report": .string(reportName)])
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

    /// Makes `name` the key (or, with nil, clears it), refusing when the
    /// records cannot all be named by it or links would change meaning.
    func setKey(_ name: String?, before: Schema, after: inout Schema) throws(RecordStoreError) {
        let collection = before.name
        guard name != before.key else { throw .invalidSchema("\(collection)'s key is already \(name ?? "unset")") }
        // Links store keys when the target has one and ids when it has not,
        // so the key cannot appear or vanish under existing links.
        let linking = try referrers(of: collection)
        if !linking.isEmpty {
            throw .linked("\(linking.map { "\($0.schema.name).\($0.field.name)" }.joined(separator: ", ")) link to \(collection) by \(before.key == nil ? "id" : "key") — set the key before linking to it")
        }
        guard let name else {
            after.key = nil
            return
        }
        guard let index = before.fields.firstIndex(where: { $0.name == name }) else {
            throw .unknownField(collection: collection, field: name)
        }
        var field = before.fields[index]
        field.default = nil
        field = try SchemaRules.keyed(field)
        var seen: [String: Int64] = [:]
        for row in try db.query("SELECT \"id\", \(SQLText.quoted(name)) AS k FROM \(SQLText.quoted(collection)) ORDER BY \"id\"") {
            let id = id(of: row)
            guard case .text(let raw) = row["k"] else { throw .invalidSchema("#\(id) has no \(name), so it cannot be the key") }
            let key = raw.trimmingCharacters(in: .whitespaces)
            if let problem = SchemaRules.keyProblem(key) { throw .invalidSchema("#\(id)'s \(name) \"\(raw)\": \(problem)") }
            if key != raw { throw .invalidSchema("#\(id)'s \(name) \"\(raw)\" has spaces at an end — tidy it first") }
            if let other = seen[key.lowercased()] { throw .invalidSchema("#\(other) and #\(id) share the \(name) \"\(key)\" — a key names one record") }
            seen[key.lowercased()] = id
        }
        try db.exec("DROP INDEX IF EXISTS \(SQLText.quoted(SQLText.indexName(name, in: collection)))")
        if let index = SQLText.createIndex(field, in: collection) { try db.exec(index) }
        after.fields[index] = field
        after.key = name
    }

    /// A report spec names fields that exist.
    func checkReport(_ report: ReportSpec, in schema: Schema) throws(RecordStoreError) {
        let catalog = try catalog().merging([schema.name: schema], uniquingKeysWith: { $1 })
        for path in report.top { _ = try LinkPaths.field(schema, path: path, catalog: catalog) }
        for name in report.averages + report.sums { _ = try numericField(schema, name, purpose: "a report total") }
        for name in report.columns where schema.field(name) == nil { throw .unknownField(collection: schema.name, field: name) }
        if let window = report.window {
            guard let exposures = catalog[window.exposures] else { throw .unknownCollection(window.exposures) }
            for path in window.tally { _ = try LinkPaths.field(exposures, path: path, catalog: catalog) }
        }
    }

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
