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

    /// The WHERE for a query's filters and date range.
    static func whereClause(_ schema: Schema, _ query: Query, now: Date, timeZone: TimeZone) throws(RecordStoreError) -> Clause {
        var parts: [String] = []
        var binds: [Database.Value] = []
        for filter in query.filters {
            let clause = try condition(schema, filter, now: now, timeZone: timeZone)
            parts.append(clause.sql)
            binds += clause.binds
        }
        if query.since != nil || query.until != nil {
            let field = try dateField(schema, named: query.dateField)
            let column = SQLText.quoted(field.name)
            if let since = query.since {
                parts.append("\(column) >= ?")
                binds.append(.text(try bound(since, field: field, end: false, now: now, timeZone: timeZone)))
            }
            if let until = query.until {
                if field.type == .date {
                    parts.append("\(column) <= ?")
                    binds.append(.text(try bound(until, field: field, end: false, now: now, timeZone: timeZone)))
                } else {
                    // Until a DAY means through the end of it.
                    parts.append("\(column) < ?")
                    binds.append(.text(try bound(until, field: field, end: true, now: now, timeZone: timeZone)))
                }
            }
        }
        return Clause(sql: parts.isEmpty ? "1" : parts.map { "(\($0))" }.joined(separator: " AND "), binds: binds)
    }

    /// One filter as SQL.
    static func condition(_ schema: Schema, _ filter: Filter, now: Date, timeZone: TimeZone) throws(RecordStoreError) -> Clause {
        if filter.field == "id" {
            let values = try list(filter).map { (text: String) throws(RecordStoreError) -> Database.Value in
                guard let id = Int64(text.trimmingCharacters(in: .whitespaces)) else { throw .invalidQuery("id must be a whole number") }
                return .int(id)
            }
            return try compare("\"id\"", filter.op, values, allowContains: false)
        }
        guard let field = schema.fields.first(where: { $0.name == filter.field }) else {
            throw .unknownField(collection: schema.name, field: filter.field)
        }
        let column = SQLText.quoted(field.name)

        if filter.value.lowercased() == "null" {
            switch filter.op {
            case .equal: return Clause(sql: "\(column) IS NULL", binds: [])
            case .notEqual: return Clause(sql: "\(column) IS NOT NULL", binds: [])
            default: throw .invalidQuery("null only compares with = or !=")
            }
        }

        switch field.type {
        case .tags:
            let values = try list(filter).map { (t: String) -> Database.Value in .text(t.trimmingCharacters(in: .whitespaces).lowercased()) }
            let exists = "EXISTS (SELECT 1 FROM json_each(\(column)) WHERE lower(value) IN (\(values.map { _ in "?" }.joined(separator: ", "))))"
            switch filter.op {
            case .equal, .contains, .oneOf: return Clause(sql: exists, binds: values)
            case .notEqual: return Clause(sql: "\(column) IS NULL OR NOT \(exists)", binds: values)
            default: throw .invalidQuery("tags compare with ~ (has the tag), =, != or in")
            }
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
            let currency = SQLText.quoted(field.name + SchemaRules.currencySuffix)
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
                guard field.type == .choice else { throw .invalidQuery("~ (contains) works on text and tags") }
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

    /// The SELECT expression that buckets a date field into a period.
    static func periodExpression(_ field: Field, _ period: Grouping.Period) -> String {
        let column = SQLText.quoted(field.name)
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
        guard op != .contains else { throw .invalidQuery("~ (contains) works on text and tags") }
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
    private static func bound(_ text: String, field: Field, end: Bool, now: Date, timeZone: TimeZone) throws(RecordStoreError) -> String {
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
