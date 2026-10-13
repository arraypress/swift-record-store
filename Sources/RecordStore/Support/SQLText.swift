//
//  SQLText.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// SQL assembly helpers. Names are validated identifiers before they get
/// here; quoting is the second line of defence, not the first.
enum SQLText {

    /// `"name"`, with any quote doubled.
    static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A `LIKE` pattern matching `text` anywhere, with the wildcards in it escaped.
    static func containsPattern(_ text: String) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// The CREATE TABLE for a schema.
    static func createTable(_ schema: Schema) -> String {
        let columns = ["\"id\" INTEGER PRIMARY KEY AUTOINCREMENT"]
            + schema.fields.flatMap(SchemaRules.declarations(of:))
            + SchemaRules.metaColumns.map { "\(quoted($0)) TEXT" }
        return "CREATE TABLE \(quoted(schema.name)) (\(columns.joined(separator: ", ")))"
    }

    /// The indexes a schema wants: unique fields, date fields, the source hash.
    static func createIndexes(_ schema: Schema) -> [String] {
        var out = ["CREATE INDEX \(quoted(schema.name + "__source")) ON \(quoted(schema.name)) (\"_source_sha256\")"]
        for field in schema.fields {
            if let index = createIndex(field, in: schema.name) { out.append(index) }
        }
        return out
    }

    /// The index one field wants, if any.
    static func createIndex(_ field: Field, in table: String) -> String? {
        let columns = SchemaRules.columns(of: field).map(quoted).joined(separator: ", ")
        if field.unique {
            return "CREATE UNIQUE INDEX \(quoted(indexName(field.name, in: table))) ON \(quoted(table)) (\(columns))"
        }
        if field.type == .date || field.type == .datetime {
            return "CREATE INDEX \(quoted(indexName(field.name, in: table))) ON \(quoted(table)) (\(columns))"
        }
        return nil
    }

    static func indexName(_ field: String, in table: String) -> String {
        "\(table)__\(field)"
    }
}
