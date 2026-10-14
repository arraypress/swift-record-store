//
//  RecordStore+Query.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Reading: records that match, or summaries of them. Money is summed in
//  SQL as integer minor units and grouped by currency, so a total is exact
//  and two currencies are never added together — a GBP and a EUR total come
//  back as two rows.
//

import Foundation

public extension RecordStore {

    /// Runs a query: matching records, or — with aggregates or groupings —
    /// a summary of them.
    func query(_ collection: String, _ query: Query) throws(RecordStoreError) -> ResultTable {
        let schema = try schema(named: collection)
        if let limit = query.limit, limit < 1 { throw .invalidQuery("the limit must be at least 1") }
        if !query.aggregates.isEmpty || !query.groupBy.isEmpty {
            return try summary(schema, query)
        }
        return try listing(schema, query, includeMeta: false)
    }

    /// Every record with its provenance, in id order — what export writes.
    func export(_ collection: String) throws(RecordStoreError) -> ResultTable {
        try listing(try schema(named: collection), Query(), includeMeta: true)
    }

    /// Matching records as typed values.
    func records(_ collection: String, _ query: Query = Query()) throws(RecordStoreError) -> [Record] {
        let schema = try schema(named: collection)
        let clause = try QueryPlanning.whereClause(schema, query, now: now(), timeZone: timeZone, table: "\"r\"", catalog: try catalog())
        var sql = "SELECT * FROM \(SQLText.quoted(schema.name)) AS \"r\" WHERE \(clause.sql) ORDER BY \"id\""
        if let limit = query.limit { sql += " LIMIT \(limit)" }
        return try db.query(sql, clause.binds).map { record(from: $0, schema: schema) }
    }

    /// Matching records of a collection, decoded into an app's own type —
    /// the struct `store schema NAME --emit swift` writes.
    func fetch<T: StoredRecord>(_ type: T.Type, _ query: Query = Query()) throws(RecordStoreError) -> [T] {
        try records(T.collection, query).map { (record: Record) throws(RecordStoreError) -> T in try record.decoded(as: T.self) }
    }
}

extension RecordStore {

    /// Every schema by name — what paths through links are resolved against.
    func catalog() throws(RecordStoreError) -> [String: Schema] {
        Dictionary(try schemas().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Listing

    func listing(_ schema: Schema, _ query: Query, includeMeta: Bool) throws(RecordStoreError) -> ResultTable {
        let clause = try QueryPlanning.whereClause(schema, query, now: now(), timeZone: timeZone, table: "\"r\"", catalog: try catalog())
        let running = try query.running.map { (name: String) throws(RecordStoreError) -> Field in try numericField(schema, name, purpose: "a running total") }
        var orderSQL = "\"id\""
        if running != nil, query.order.isEmpty {
            let dateField = try? QueryPlanning.dateField(schema, named: query.dateField)
            orderSQL = dateField.map { "\(SQLText.quoted($0.name)), \"id\"" } ?? "\"id\""
        } else if !query.order.isEmpty {
            orderSQL = try query.order.map { (o: Ordering) throws(RecordStoreError) -> String in
                guard o.key == "id" || schema.fields.contains(where: { $0.name == o.key }) else {
                    throw .unknownField(collection: schema.name, field: o.key)
                }
                return SQLText.quoted(o.key) + (o.descending ? " DESC" : " ASC")
            }.joined(separator: ", ") + ", \"id\""
        }
        // A running total needs every earlier row, so the limit applies after it.
        var sql = "SELECT * FROM \(SQLText.quoted(schema.name)) AS \"r\" WHERE \(clause.sql) ORDER BY \(orderSQL)"
        if let limit = query.limit, running == nil { sql += " LIMIT \(limit)" }

        var columns = ["id"] + schema.fields.map(\.name)
        if includeMeta { columns += ["_source", "_source_sha256", "_tool", "_added_at", "_updated_at"] }
        var rows: [[String: JSONValue]] = []
        for raw in try db.query(sql, clause.binds) {
            let record = record(from: raw, schema: schema)
            var row = record.values
            row["id"] = .number(Decimal(record.id))
            if includeMeta {
                row["_source"] = record.provenance.source.map(JSONValue.string) ?? .null
                row["_source_sha256"] = record.provenance.sourceSHA256.map(JSONValue.string) ?? .null
                row["_tool"] = record.provenance.tool.map(JSONValue.string) ?? .null
                row["_added_at"] = .string(record.addedAt)
                row["_updated_at"] = record.updatedAt.map(JSONValue.string) ?? .null
            }
            rows.append(row)
        }
        if let running {
            let name = running.name + "_running"
            columns.append(name)
            rows = Accumulation.running(rows, source: running.name, into: name, money: running.type == .money)
            if let limit = query.limit { rows = Array(rows.prefix(limit)) }
        }
        return ResultTable(columns: columns, rows: rows)
    }

    // MARK: Summaries

    /// Groups and aggregates in two steps. The inner query lists each
    /// matching record once per distinct group it falls in — a list field
    /// (tags, refs) spreads a record over its items, a path joins what it
    /// links to — and the outer one aggregates the records themselves, so
    /// a record is never counted (or summed) twice inside one group.
    func summary(_ schema: Schema, _ query: Query) throws(RecordStoreError) -> ResultTable {
        let catalog = try catalog()
        let base = "\"r\"", grouped = "\"g\"", table = SQLText.quoted(schema.name)
        let clause = try QueryPlanning.whereClause(schema, query, now: now(), timeZone: timeZone, table: base, catalog: catalog)

        var joins: [String] = []
        var keySelects = ["\(base).\"id\" AS \"_rid\""]
        var groupAliases: [String] = []
        var groupColumns: [String] = []
        var readers: [(column: String, aliases: [String], field: Field?, spread: Bool)] = []
        var counter = 0
        for (index, grouping) in query.groupBy.enumerated() {
            switch grouping {
            case .field(let path):
                let key = try LinkPaths.key(schema, path: path, table: base, catalog: catalog, counter: &counter)
                joins += key.joins
                var aliases: [String] = []
                for (n, expression) in key.columns.enumerated() {
                    let alias = "g_\(index)_\(n)"
                    keySelects.append("\(expression) AS \(SQLText.quoted(alias))")
                    groupAliases.append(alias)
                    aliases.append(alias)
                }
                groupColumns.append(path)
                readers.append((path, aliases, key.field, key.spread && key.columns.count == 1 && key.field.isList))
            case .period(let period):
                let field = try QueryPlanning.dateField(schema, named: query.dateField)
                let alias = "g_\(index)_0"
                keySelects.append("\(QueryPlanning.periodExpression(field, period, table: base)) AS \(SQLText.quoted(alias))")
                groupAliases.append(alias)
                groupColumns.append(period.rawValue)
                readers.append((period.rawValue, [alias], nil, false))
            }
        }

        var aggregates = query.aggregates
        if let running = query.running, !aggregates.contains(.sum(running)) { aggregates.append(.sum(running)) }
        if aggregates.isEmpty { aggregates = [.count] }

        // Money aggregates group by their currency too, so no total ever
        // crosses currencies.
        var selects = groupAliases.map { "\(grouped).\(SQLText.quoted($0)) AS \(SQLText.quoted($0))" }
        var currencyGroups: [String] = []
        var moneyFields: [Field] = []
        var resultColumns = groupColumns
        var specs: [(alias: String, column: String, field: Field?, kind: String)] = []
        func column(_ name: String) -> String { base + "." + SQLText.quoted(name) }
        for aggregate in aggregates {
            switch aggregate {
            case .count:
                selects.append("COUNT(*) AS \"a_count\"")
                specs.append(("a_count", "count", nil, "count"))
                resultColumns.append("count")
            case .sum(let name), .average(let name), .minimum(let name), .maximum(let name):
                let kind: String, sqlFunction: String
                switch aggregate {
                case .sum: (kind, sqlFunction) = ("sum", "SUM")
                case .average: (kind, sqlFunction) = ("avg", "SUM")
                case .minimum: (kind, sqlFunction) = ("min", "MIN")
                default: (kind, sqlFunction) = ("max", "MAX")
                }
                let field = try kind == "min" || kind == "max"
                    ? orderableField(schema, name)
                    : numericField(schema, name, purpose: kind == "sum" ? "a sum" : "an average")
                if field.type == .money, !moneyFields.contains(field) {
                    moneyFields.append(field)
                    let alias = "c_\(field.name)"
                    selects.append("\(column(field.name + SchemaRules.currencySuffix)) AS \(SQLText.quoted(alias))")
                    currencyGroups.append(SQLText.quoted(alias))
                }
                let alias = "a_\(field.name)_\(kind)"
                selects.append("\(sqlFunction)(\(column(field.name))) AS \(SQLText.quoted(alias))")
                if kind == "avg" {
                    selects.append("COUNT(\(column(field.name))) AS \(SQLText.quoted(alias + "_n"))")
                }
                specs.append((alias, "\(field.name)_\(kind)", field, kind))
                resultColumns.append("\(field.name)_\(kind)")
            }
        }

        let inner = "SELECT DISTINCT \(keySelects.joined(separator: ", ")) FROM \(table) AS \(base) \(joins.joined(separator: " ")) WHERE \(clause.sql)"
        var sql = "SELECT \(selects.joined(separator: ", ")) FROM (\(inner)) AS \(grouped) JOIN \(table) AS \(base) ON \(base).\"id\" = \(grouped).\"_rid\" WHERE 1"
        // Rows with no currency (an empty money field) are left out of money
        // aggregates rather than forming a currency-less group.
        if !moneyFields.isEmpty {
            sql += " AND " + moneyFields.map { "\(column($0.name + SchemaRules.currencySuffix)) IS NOT NULL" }.joined(separator: " AND ")
        }
        let allGroups = groupAliases.map(SQLText.quoted) + currencyGroups
        if !allGroups.isEmpty { sql += " GROUP BY \(allGroups.joined(separator: ", ")) ORDER BY \(allGroups.joined(separator: ", "))" }

        var rows: [[String: JSONValue]] = []
        for raw in try db.query(sql, clause.binds) {
            var row: [String: JSONValue] = [:]
            for reader in readers {
                let cells = reader.aliases.map { raw[$0] }
                guard let field = reader.field, !reader.spread else {
                    row[reader.column] = ValueCoercion.raw(cells.first ?? .null)
                    continue
                }
                let renamed = Database.Row(columns: SchemaRules.columns(of: field), values: cells)
                row[reader.column] = ValueCoercion.output(renamed, field: field)
            }
            for spec in specs {
                row[spec.column] = Accumulation.aggregateValue(raw, alias: spec.alias, field: spec.field, kind: spec.kind)
            }
            rows.append(row)
        }

        if let running = query.running {
            let field = try numericField(schema, running, purpose: "a running total")
            let name = running + "_running"
            resultColumns.append(name)
            rows = Accumulation.running(rows, source: running + "_sum", into: name, money: field.type == .money)
        }

        if !query.order.isEmpty {
            let order = try query.order.map { (ordering: Ordering) throws(RecordStoreError) -> Ordering in
                try QueryPlanning.summaryOrdering(ordering, columns: resultColumns)
            }
            rows = Accumulation.sorted(rows, by: order)
        }
        if let limit = query.limit { rows = Array(rows.prefix(limit)) }
        return ResultTable(columns: resultColumns, rows: rows)
    }

    // MARK: Field checks

    func numericField(_ schema: Schema, _ name: String, purpose: String) throws(RecordStoreError) -> Field {
        guard let field = schema.fields.first(where: { $0.name == name }) else {
            throw .unknownField(collection: schema.name, field: name)
        }
        guard [.number, .integer, .money].contains(field.type) else {
            throw .invalidQuery("\(name) is \(field.type.rawValue) — \(purpose) needs a number, integer or money field")
        }
        return field
    }

    func orderableField(_ schema: Schema, _ name: String) throws(RecordStoreError) -> Field {
        guard let field = schema.fields.first(where: { $0.name == name }) else {
            throw .unknownField(collection: schema.name, field: name)
        }
        guard ![.tags, .bool, .refs, .range].contains(field.type) else {
            throw .invalidQuery("\(name) is \(field.type.rawValue) — it has no minimum or maximum")
        }
        return field
    }
}
