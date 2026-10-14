//
//  RecordStore+Window.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  "What came before": the records of one collection that fell in a window
//  before each record of another — meals before symptoms, coffee before
//  migraines, late nights before bad runs — and which of their values turn
//  up there more often than they turn up at all. Nothing here knows about
//  food; the arithmetic is in WindowMath.
//

import Foundation

public extension RecordStore {

    /// Runs a ``WindowSpec``.
    func window(_ spec: WindowSpec) throws(RecordStoreError) -> WindowAnalysis {
        guard !spec.tally.isEmpty else { throw .invalidQuery("name at least one field of \(spec.exposures) to count") }
        let catalog = try catalog()
        let events = try schema(named: spec.events)
        let exposures = try schema(named: spec.exposures)
        let eventDate = try datetimeField(events, named: spec.dateField)
        let exposureDate = try datetimeField(exposures, named: spec.exposureDateField)
        let base = "\"r\""

        // The events and their times.
        let eventQuery = Query(filters: spec.filters, since: spec.since, until: spec.until, dateField: eventDate.name)
        let eventClause = try QueryPlanning.whereClause(events, eventQuery, now: now(), timeZone: timeZone, table: base, catalog: catalog)
        let eventFrom = "FROM \(SQLText.quoted(events.name)) AS \(base)"
        var times: [(Int64, Date)] = []
        for row in try db.query("SELECT \(base).\"id\" AS \"_id\", \(base).\(SQLText.quoted(eventDate.name)) AS \"_t\" \(eventFrom) WHERE \(eventClause.sql) AND \(base).\(SQLText.quoted(eventDate.name)) IS NOT NULL ORDER BY \"_t\"", eventClause.binds) {
            guard case .int(let id) = row["_id"], case .text(let t) = row["_t"], let time = DateParsing.instant(t) else { continue }
            times.append((id, time))
        }

        // Each event's window: fixed, or read from a range field it reaches.
        var windows: [Int64: (from: Double, to: Double)] = [:]
        switch spec.within {
        case .fixed(let from, let to):
            guard from >= 0, from <= to else { throw .invalidQuery("a window runs from nearer to further back, e.g. 30m..3h") }
            for (id, _) in times { windows[id] = (from, to) }
        case .field(let path, let unit):
            var counter = 0
            let key = try LinkPaths.key(events, path: path, table: base, catalog: catalog, counter: &counter, allowRange: true)
            guard key.field.type == .range, key.columns.count == 2 else {
                throw .invalidQuery("\(path) is \(key.field.type.rawValue) — a window is read from a range field, e.g. [0.5, 3]")
            }
            let sql = "SELECT \(base).\"id\" AS \"_id\", MIN(\(key.columns[0])) AS \"_lo\", MAX(\(key.columns[1])) AS \"_hi\" \(eventFrom) "
                + key.joins.joined(separator: " ") + " WHERE \(eventClause.sql) GROUP BY \(base).\"id\""
            for row in try db.query(sql, eventClause.binds) {
                guard case .int(let id) = row["_id"], let low = row["_lo"].double, let high = row["_hi"].double else { continue }
                windows[id] = (low * unit, high * unit)
            }
        }

        // The exposures in the period, and the values of each tallied field.
        let exposureQuery = Query(filters: spec.exposureFilters, since: spec.since, until: spec.until, dateField: exposureDate.name)
        let exposureClause = try QueryPlanning.whereClause(exposures, exposureQuery, now: now(), timeZone: timeZone, table: base, catalog: catalog)
        let exposureFrom = "FROM \(SQLText.quoted(exposures.name)) AS \(base)"
        var exposureRows: [WindowMath.Exposure] = []
        for row in try db.query("SELECT \(base).\"id\" AS \"_id\", \(base).\(SQLText.quoted(exposureDate.name)) AS \"_t\" \(exposureFrom) WHERE \(exposureClause.sql)", exposureClause.binds) {
            guard case .int(let id) = row["_id"], case .text(let t) = row["_t"], let time = DateParsing.instant(t) else { continue }
            exposureRows.append(WindowMath.Exposure(id: id, time: time))
        }
        var values: [String: [Int64: [JSONValue]]] = [:]
        for path in spec.tally {
            var counter = 0
            let key = try LinkPaths.key(exposures, path: path, table: base, catalog: catalog, counter: &counter)
            guard key.columns.count == 1, ![.money, .number, .date, .datetime].contains(key.field.type) else {
                throw .invalidQuery("\(path) is \(key.field.type.rawValue) — count tags, links, choices, text, whole numbers or yes/no")
            }
            let sql = "SELECT DISTINCT \(base).\"id\" AS \"_id\", \(key.columns[0]) AS \"_v\" \(exposureFrom) "
                + key.joins.joined(separator: " ") + " WHERE \(exposureClause.sql)"
            var byID: [Int64: [JSONValue]] = [:]
            for row in try db.query(sql, exposureClause.binds) {
                guard case .int(let id) = row["_id"] else { continue }
                let value = key.field.isList
                    ? ValueCoercion.raw(row["_v"])
                    : ValueCoercion.output(Database.Row(columns: [key.field.name], values: [row["_v"]]), field: key.field)
                byID[id, default: []].append(value)
            }
            values[path] = byID
        }

        let result = WindowMath.analyse(events: times.map { WindowMath.Event(id: $0.0, time: $0.1, window: windows[$0.0]) },
                                        exposures: exposureRows, tally: spec.tally, values: values, minEvents: spec.minEvents)
        return WindowAnalysis(events: times.count, covered: result.covered, skipped: result.skipped,
                              exposures: exposureRows.count, matched: result.matched, table: result.table)
    }
}

extension RecordStore {

    /// The datetime field a window is measured on.
    func datetimeField(_ schema: Schema, named: String?) throws(RecordStoreError) -> Field {
        if let named {
            guard let field = schema.field(named) else { throw .unknownField(collection: schema.name, field: named) }
            guard field.type == .datetime else {
                throw .invalidQuery("\(named) is \(field.type.rawValue) — windows of hours need a datetime field")
            }
            return field
        }
        let candidates = schema.fields.filter { $0.type == .datetime }
        guard candidates.count == 1 else {
            throw .invalidQuery(candidates.isEmpty
                ? "\(schema.name) has no datetime field — windows of hours need one"
                : "\(schema.name) has several datetime fields (\(candidates.map(\.name).joined(separator: ", "))) — name one")
        }
        return candidates[0]
    }
}

private extension Database.Value {
    var double: Double? {
        switch self {
        case .real(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
