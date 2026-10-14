//
//  QueryPlanning.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A Query becomes SQL here: the WHERE clause with its bindings, the date
//  field that ranges and periods use, and the SELECT for aggregates. Every
//  value a filter compares against goes through ValueCoercion first, so
//  `date >= "13 Oct 2026"` and `category = Groceries` match what was
//  stored, and every value is a binding, never spliced text.
//

import Foundation

enum QueryPlanning {

    /// A WHERE clause (without the keyword; `1` when empty) and its bindings.
    struct Clause {
        var sql: String
        var binds: [Database.Value]
    }

    /// The date or datetime field a query's ranges and periods use.
    static func dateField(_ schema: Schema, named: String?) throws(RecordStoreError) -> Field {
        let candidates = schema.fields.filter { $0.type == .date || $0.type == .datetime }
        if let named {
            guard let field = schema.fields.first(where: { $0.name == named }) else {
                throw .unknownField(collection: schema.name, field: named)
            }
            guard field.type == .date || field.type == .datetime else {
                throw .invalidQuery("\"\(named)\" is \(field.type.rawValue), not a date")
            }
            return field
        }
        guard let only = candidates.first else {
            throw .invalidQuery("\(schema.name) has no date field to range or bucket by")
        }
        guard candidates.count == 1 else {
            throw .invalidQuery("\(schema.name) has several date fields (\(candidates.map(\.name).joined(separator: ", "))) — name one with the date field option")
        }
        return only
    }

    /// The WHERE for a query's filters and date range. Columns are read
    /// through `table` (an alias or the table's quoted name); `catalog` holds
    /// every collection, for filters that follow links (`category.label`).
    static func whereClause(_ schema: Schema, _ query: Query, now: Date, timeZone: TimeZone,
                            table: String? = nil, catalog: [String: Schema] = [:]) throws(RecordStoreError) -> Clause {
        let table = table ?? SQLText.quoted(schema.name)
        var parts: [String] = []
        var binds: [Database.Value] = []
        var depth = 0
        for filter in query.filters {
            let clause = try condition(schema, filter, now: now, timeZone: timeZone, table: table, catalog: catalog, depth: &depth)
            parts.append(clause.sql)
            binds += clause.binds
        }
        if query.since != nil || query.until != nil {
            let field = try dateField(schema, named: query.dateField)
            let range = try dateRange(field, since: query.since, until: query.until, now: now, timeZone: timeZone)
            let column = table + "." + SQLText.quoted(field.name)
            if let low = range.low { parts.append("\(column) >= ?"); binds.append(.text(low)) }
            if let high = range.high { parts.append("\(column) \(range.highInclusive ? "<=" : "<") ?"); binds.append(.text(high)) }
        }
        return Clause(sql: parts.isEmpty ? "1" : parts.map { "(\($0))" }.joined(separator: " AND "), binds: binds)
    }

    /// Since/until in a date field's stored form. Until a day, for a
    /// datetime field, means through the end of it.
    static func dateRange(_ field: Field, since: String?, until: String?, now: Date,
                          timeZone: TimeZone) throws(RecordStoreError) -> (low: String?, high: String?, highInclusive: Bool) {
        let low = try since.map { (text: String) throws(RecordStoreError) -> String in
            try bound(text, field: field, end: false, now: now, timeZone: timeZone)
        }
        guard let until else { return (low, nil, true) }
        if field.type == .date { return (low, try bound(until, field: field, end: false, now: now, timeZone: timeZone), true) }
        return (low, try bound(until, field: field, end: true, now: now, timeZone: timeZone), false)
    }

    /// One filter as SQL. A dotted field follows a link: `category.label =
    /// Gut` matches records whose category's label is Gut, and
    /// through a list of links, records with any such item.
    static func condition(_ schema: Schema, _ filter: Filter, now: Date, timeZone: TimeZone,
                          table: String, catalog: [String: Schema], depth: inout Int) throws(RecordStoreError) -> Clause {
        if let dot = filter.field.firstIndex(of: ".") {
            let name = String(filter.field[..<dot])
            let rest = String(filter.field[filter.field.index(after: dot)...])
            guard let field = schema.field(name) else { throw .unknownField(collection: schema.name, field: name) }
            let target = try linkTarget(field, in: schema, catalog: catalog)
            depth += 1
            let alias = SQLText.quoted("l\(depth)")
            let inner = try condition(target, Filter(field: rest, op: filter.op, value: filter.value), now: now, timeZone: timeZone,
                                      table: alias, catalog: catalog, depth: &depth)
            let matching = "SELECT \(alias).\(SQLText.quoted(target.linkColumn)) FROM \(SQLText.quoted(target.name)) AS \(alias) WHERE \(inner.sql)"
            let column = table + "." + SQLText.quoted(field.name)
            if field.type == .ref {
                return Clause(sql: "\(column) IN (\(matching))", binds: inner.binds)
            }
            depth += 1
            let each = SQLText.quoted("e\(depth)")
            return Clause(sql: "EXISTS (SELECT 1 FROM json_each(\(column)) AS \(each) WHERE \(each).\"value\" IN (\(matching)))", binds: inner.binds)
        }
        if filter.field == "id" {
            let values = try list(filter).map { (text: String) throws(RecordStoreError) -> Database.Value in
                guard let id = Int64(text.trimmingCharacters(in: .whitespaces)) else { throw .invalidQuery("id must be a whole number") }
                return .int(id)
            }
            return try compare(table + ".\"id\"", filter.op, values, allowContains: false)
        }
        guard let field = schema.field(filter.field) else {
            throw .unknownField(collection: schema.name, field: filter.field)
        }
        let column = table + "." + SQLText.quoted(field.name)

        if filter.value.lowercased() == "null" {
            switch filter.op {
            case .equal: return Clause(sql: "\(column) IS NULL", binds: [])
            case .notEqual: return Clause(sql: "\(column) IS NOT NULL", binds: [])
            default: throw .invalidQuery("null only compares with = or !=")
            }
        }

        switch field.type {
        case .tags, .refs:
            depth += 1
            let each = SQLText.quoted("e\(depth)")
            let values = list(filter).map { (t: String) -> Database.Value in .text(t.trimmingCharacters(in: .whitespaces).lowercased()) }
            let exists = "EXISTS (SELECT 1 FROM json_each(\(column)) AS \(each) WHERE lower(\(each).\"value\") IN (\(values.map { _ in "?" }.joined(separator: ", "))))"
            switch filter.op {
            case .equal, .contains, .oneOf: return Clause(sql: exists, binds: values)
            case .notEqual: return Clause(sql: "\(column) IS NULL OR NOT \(exists)", binds: values)
            default: throw .invalidQuery("\(field.type.rawValue) compare with ~ (has the item), =, != or in")
            }
        case .ref:
            switch filter.op {
            case .contains:
                return Clause(sql: "\(column) LIKE ? ESCAPE '\\'", binds: [.text(SQLText.containsPattern(filter.value))])
            case .equal, .notEqual, .oneOf:
                let values = list(filter).map { (t: String) -> Database.Value in .text(t.trimmingCharacters(in: .whitespaces).lowercased()) }
                let inList = "lower(\(column)) IN (\(values.map { _ in "?" }.joined(separator: ", ")))"
                return Clause(sql: filter.op == .notEqual ? "\(column) IS NULL OR NOT \(inList)" : inList, binds: values)
            default:
                throw .invalidQuery("a link compares with =, !=, in or ~ — or follow it: \(field.name).<field>")
            }
        case .range:
            guard filter.op == .contains else { throw .invalidQuery("a range compares with ~ (contains the number)") }
            let number: Decimal
            do throws(CoercionFailure) { number = try ValueCoercion.number(.string(filter.value)) } catch {
                throw .invalidQuery("\(field.name): \(error.reason)")
            }
            let high = table + "." + SQLText.quoted(field.name + SchemaRules.rangeSuffix)
            let value = Database.Value.real(NSDecimalNumber(decimal: number).doubleValue)
            return Clause(sql: "\(column) <= ? AND \(high) >= ?", binds: [value, value])
        case .money:
            guard filter.op != .contains, filter.op != .oneOf else {
                throw .invalidQuery("money compares with = != < <= > >=")
            }
            let money: Money
            do throws(MoneyFailure) {
                money = try MoneyParsing.parse(filter.value, defaultCurrency: field.currency)
            } catch {
                throw .invalidQuery("\(field.name): \(error.reason)")
            }
            let currency = table + "." + SQLText.quoted(field.name + SchemaRules.currencySuffix)
            let inner = "\(currency) = ? AND \(column) \(sqlOperator(filter.op == .notEqual ? .equal : filter.op)) ?"
            let binds: [Database.Value] = [.text(money.currency), .int(money.minorUnits)]
            return Clause(sql: filter.op == .notEqual ? "NOT (\(inner))" : inner, binds: binds)
        case .text:
            if filter.op == .contains {
                return Clause(sql: "\(column) LIKE ? ESCAPE '\\'", binds: [.text(SQLText.containsPattern(filter.value))])
            }
            return try compare(column, filter.op, list(filter).map { .text($0) }, allowContains: false)
        case .bool:
            guard filter.op == .equal || filter.op == .notEqual else { throw .invalidQuery("yes/no fields compare with = or !=") }
            fallthrough
        default:
            if filter.op == .contains {
                guard field.type == .choice else { throw .invalidQuery("~ (contains) works on text, tags and links") }
                return Clause(sql: "\(column) LIKE ? ESCAPE '\\'", binds: [.text(SQLText.containsPattern(filter.value))])
            }
            var values: [Database.Value] = []
            for item in list(filter) {
                do throws(CoercionFailure) {
                    let columns = try ValueCoercion.columns(for: .string(item.trimmingCharacters(in: .whitespaces)), field: field, now: now, timeZone: timeZone)
                    values.append(columns[0])
                } catch {
                    throw .invalidQuery("\(field.name): \(error.reason)")
                }
            }
            return try compare(column, filter.op, values, allowContains: false)
        }
    }

    /// The collection a link field points at, for a path through it.
    static func linkTarget(_ field: Field, in schema: Schema, catalog: [String: Schema]) throws(RecordStoreError) -> Schema {
        guard field.isLink, let name = field.target else {
            throw .invalidQuery("\(field.name) is \(field.type.rawValue), not a link — only ref and refs fields can be followed with a dot")
        }
        guard let target = catalog[name] else { throw .unknownCollection(name) }
        return target
    }

    /// The SELECT expression that buckets a date field into a period.
    /// A summary's sort key as a result column. A field name stands for its
    /// one aggregate — `-total` sorts by `total_sum` when that is the only
    /// `total_…` column; with two (`total_sum`, `total_avg`) it must be named.
    static func summaryOrdering(_ ordering: Ordering, columns: [String]) throws(RecordStoreError) -> Ordering {
        if columns.contains(ordering.key) { return ordering }
        let candidates = columns.filter { $0.hasPrefix(ordering.key + "_") && !$0.hasSuffix("_running") }
        guard candidates.count == 1 else {
            let hint = candidates.count > 1 ? "\"\(ordering.key)\" could be \(candidates.joined(separator: " or "))" : "the columns are \(columns.joined(separator: ", "))"
            throw .invalidQuery("cannot order by \"\(ordering.key)\" — \(hint)")
        }
        return Ordering(key: candidates[0], descending: ordering.descending)
    }

    static func periodExpression(_ field: Field, _ period: Grouping.Period, table: String? = nil) -> String {
        let column = (table.map { $0 + "." } ?? "") + SQLText.quoted(field.name)
        switch period {
        case .day: return "substr(\(column), 1, 10)"
        case .month: return "substr(\(column), 1, 7)"
        case .year: return "substr(\(column), 1, 4)"
        // Monday-started weeks, numbered 00–53 within the year: portable to
        // every SQLite an app might ship with (ISO %G/%V needs 3.46).
        case .week: return "strftime('%Y-W%W', \(column))"
        }
    }

    // MARK: Internals

    private static func list(_ filter: Filter) -> [String] {
        filter.op == .oneOf ? filter.value.split(separator: ",").map(String.init) : [filter.value]
    }

    private static func compare(_ column: String, _ op: FilterOperator, _ values: [Database.Value], allowContains: Bool) throws(RecordStoreError) -> Clause {
        if op == .oneOf {
            return Clause(sql: "\(column) IN (\(values.map { _ in "?" }.joined(separator: ", ")))", binds: values)
        }
        guard op != .contains else { throw .invalidQuery("~ (contains) works on text, tags and links") }
        return Clause(sql: "\(column) \(sqlOperator(op)) ?", binds: Array(values.prefix(1)))
    }

    private static func sqlOperator(_ op: FilterOperator) -> String {
        switch op {
        case .equal: return "="
        case .notEqual: return "!="
        case .less: return "<"
        case .lessOrEqual: return "<="
        case .greater: return ">"
        case .greaterOrEqual: return ">="
        case .contains, .oneOf: return "="
        }
    }

    /// A range bound in the field's stored form.
    static func bound(_ text: String, field: Field, end: Bool, now: Date, timeZone: TimeZone) throws(RecordStoreError) -> String {
        do throws(DateFailure) {
            if field.type == .date { return try DateParsing.date(text, now: now, timeZone: timeZone) }
            let isDayOnly = (try? DateParsing.date(text, now: now, timeZone: timeZone)) != nil
                && text.firstMatch(of: /\d{2}:\d{2}/) == nil
            if isDayOnly {
                let day = try DateParsing.date(text, now: now, timeZone: timeZone)
                let start = try DateParsing.datetime(day + "T00:00:00", now: now, timeZone: timeZone)
                guard end else { return start }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                let parts = day.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3,
                      let midnight = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                      let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { return start }
                return DateParsing.utc(next)
            }
            return try DateParsing.datetime(text, now: now, timeZone: timeZone)
        } catch {
            throw .invalidQuery(error.reason)
        }
    }
}
