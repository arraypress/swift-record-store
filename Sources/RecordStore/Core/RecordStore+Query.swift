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
        let clause = try QueryPlanning.whereClause(schema, query, now: now(), timeZone: timeZone)
        var sql = "SELECT * FROM \(SQLText.quoted(schema.name)) WHERE \(clause.sql) ORDER BY \"id\""
        if let limit = query.limit { sql += " LIMIT \(limit)" }
        return try db.query(sql, clause.binds).map { record(from: $0, schema: schema) }
    }
}

extension RecordStore {

    // MARK: Listing

    func listing(_ schema: Schema, _ query: Query, includeMeta: Bool) throws(RecordStoreError) -> ResultTable {
        let clause = try QueryPlanning.whereClause(schema, query, now: now(), timeZone: timeZone)
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
        var sql = "SELECT * FROM \(SQLText.quoted(schema.name)) WHERE \(clause.sql) ORDER BY \(orderSQL)"
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

    func summary(_ schema: Schema, _ query: Query) throws(RecordStoreError) -> ResultTable {
        let clause = try QueryPlanning.whereClause(schema, query, now: now(), timeZone: timeZone)

        // Grouping by a tags field counts each record once under every tag it
        // has: the matching records are filtered first, then spread over
        // json_each, and every column is read through the record alias so a
        // field called `type` or `value` never meets json_each's own columns.
        let tagGroups = query.groupBy.compactMap { grouping -> Field? in
            guard case .field(let name) = grouping else { return nil }
            return schema.fields.first { $0.name == name && $0.type == .tags }
        }
        if tagGroups.count > 1 { throw .invalidQuery("group by one tags field at a time") }
        let tagField = tagGroups.first
        let record = "r", tag = "t"
        func column(_ name: String) -> String {
            (tagField == nil ? "" : SQLText.quoted(record) + ".") + SQLText.quoted(name)
        }

        var selects: [String] = []
        var groupSQL: [String] = []
        var groupColumns: [String] = []
        for grouping in query.groupBy {
            switch grouping {
            case .field(let name):
                guard let field = schema.fields.first(where: { $0.name == name }) else {
                    throw .unknownField(collection: schema.name, field: name)
                }
                if field.type == .tags {
                    selects.append("\(SQLText.quoted(tag)).\"value\" AS \(SQLText.quoted("g_\(field.name)"))")
                    groupSQL.append(SQLText.quoted("g_\(field.name)"))
                } else {
                    for (index, name) in SchemaRules.columns(of: field).enumerated() {
                        let alias = index == 0 ? "g_\(field.name)" : "g_\(field.name)\(SchemaRules.currencySuffix)"
                        selects.append("\(column(name)) AS \(SQLText.quoted(alias))")
                        groupSQL.append(SQLText.quoted(alias))
                    }
                }
                groupColumns.append(field.name)
            case .period(let period):
                let field = try QueryPlanning.dateField(schema, named: query.dateField)
                selects.append("\(QueryPlanning.periodExpression(field, period, table: tagField == nil ? nil : record)) AS \(SQLText.quoted("g_" + period.rawValue))")
                groupSQL.append(SQLText.quoted("g_" + period.rawValue))
                groupColumns.append(period.rawValue)
            }
        }

        var aggregates = query.aggregates
        if let running = query.running, !aggregates.contains(.sum(running)) { aggregates.append(.sum(running)) }
        if aggregates.isEmpty { aggregates = [.count] }

        // Money aggregates group by their currency too, so no total ever
        // crosses currencies.
        var moneyFields: [Field] = []
        var resultColumns = groupColumns
        var specs: [(alias: String, column: String, field: Field?, kind: String)] = []
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
                    groupSQL.append(SQLText.quoted(alias))
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

        var sql: String
        if let tagField {
            sql = "SELECT \(selects.joined(separator: ", ")) FROM (SELECT * FROM \(SQLText.quoted(schema.name)) WHERE \(clause.sql)) AS \(SQLText.quoted(record)), "
                + "json_each(\(column(tagField.name))) AS \(SQLText.quoted(tag)) WHERE 1"
        } else {
            sql = "SELECT \(selects.joined(separator: ", ")) FROM \(SQLText.quoted(schema.name)) WHERE \(clause.sql)"
        }
        // Rows with no currency (an empty money field) are left out of money
        // aggregates rather than forming a currency-less group.
        if !moneyFields.isEmpty {
            sql += " AND " + moneyFields.map { "\(column($0.name + SchemaRules.currencySuffix)) IS NOT NULL" }.joined(separator: " AND ")
        }
        if !groupSQL.isEmpty { sql += " GROUP BY \(groupSQL.joined(separator: ", ")) ORDER BY \(groupSQL.joined(separator: ", "))" }

        var rows: [[String: JSONValue]] = []
        for raw in try db.query(sql, clause.binds) {
            var row: [String: JSONValue] = [:]
            for grouping in query.groupBy {
                switch grouping {
                case .field(let name):
                    guard let field = schema.fields.first(where: { $0.name == name }) else { continue }
                    if field.type == .tags {
                        row[name] = ValueCoercion.raw(raw["g_\(name)"])
                    } else if field.type == .money {
                        if case .int(let minor) = raw["g_\(name)"], case .text(let currency) = raw["g_\(name)\(SchemaRules.currencySuffix)"] {
                            row[name] = MoneyParsing.json(Money(minorUnits: minor, currency: currency))
                        } else { row[name] = .null }
                    } else {
                        let renamed = Database.Row(columns: [name], values: [raw["g_\(name)"]])
                        row[name] = ValueCoercion.output(renamed, field: field)
                    }
                case .period(let period):
                    row[period.rawValue] = ValueCoercion.raw(raw["g_" + period.rawValue])
                }
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
        guard ![.tags, .bool].contains(field.type) else {
            throw .invalidQuery("\(name) is \(field.type.rawValue) — it has no minimum or maximum")
        }
        return field
    }
}
