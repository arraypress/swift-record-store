//
//  LinkPaths.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A field path as SQL: `category` is a column; `category.label` joins the
//  linked collection and reads its label; a list (tags, refs) along the way
//  is spread with json_each, one row per item. Groupings, tallies and
//  report tables all read values this way, so a path means the same thing
//  everywhere.
//

import Foundation

enum LinkPaths {

    /// What a path needs: the joins to add after the base table, the SQL
    /// for each of the final field's columns, and that field.
    struct Key {
        var joins: [String]
        var columns: [String]
        var field: Field
        /// Whether a list was spread, so one record can yield several values.
        var spread: Bool
    }

    /// The SQL for `path`, starting from `table` (an alias of `schema`'s
    /// table). `counter` numbers the aliases so several paths can share one
    /// query.
    static func key(_ schema: Schema, path: String, table: String, catalog: [String: Schema],
                    counter: inout Int, allowRange: Bool = false) throws(RecordStoreError) -> Key {
        let segments = path.split(separator: ".").map(String.init)
        guard !segments.isEmpty else { throw .invalidQuery("an empty field path") }
        var current = schema
        var alias = table
        var joins: [String] = []
        var spread = false
        for (index, name) in segments.enumerated() {
            guard let field = current.field(name) else { throw .unknownField(collection: current.name, field: name) }
            let column = alias + "." + SQLText.quoted(field.name)
            if index == segments.count - 1 {
                if field.isList {
                    counter += 1
                    let each = SQLText.quoted("s\(counter)")
                    joins.append("JOIN json_each(\(column)) AS \(each)")
                    return Key(joins: joins, columns: [each + ".\"value\""], field: field, spread: true)
                }
                guard field.type != .range || allowRange else { throw .invalidQuery("\(name) is a range — it cannot be grouped or counted") }
                return Key(joins: joins, columns: SchemaRules.columns(of: field).map { alias + "." + SQLText.quoted($0) },
                           field: field, spread: spread)
            }
            let target = try QueryPlanning.linkTarget(field, in: current, catalog: catalog)
            counter += 1
            let joined = SQLText.quoted("j\(counter)")
            let match = joined + "." + SQLText.quoted(target.linkColumn)
            if field.type == .ref {
                joins.append("LEFT JOIN \(SQLText.quoted(target.name)) AS \(joined) ON \(match) = \(column)")
            } else {
                counter += 1
                let each = SQLText.quoted("s\(counter)")
                joins.append("JOIN json_each(\(column)) AS \(each)")
                joins.append("LEFT JOIN \(SQLText.quoted(target.name)) AS \(joined) ON \(match) = \(each).\"value\"")
                spread = true
            }
            alias = joined
            current = target
        }
        throw .invalidQuery("an empty field path")
    }

    /// The final field of a path, without building SQL.
    static func field(_ schema: Schema, path: String, catalog: [String: Schema]) throws(RecordStoreError) -> Field {
        var counter = 0
        return try key(schema, path: path, table: "\"r\"", catalog: catalog, counter: &counter).field
    }
}
