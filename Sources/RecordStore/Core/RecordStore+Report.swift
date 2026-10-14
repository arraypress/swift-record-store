//
//  RecordStore+Report.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A collection as a document someone else reads — a diary for a doctor, a
//  year of expenses for an accountant: the period, an overall line, counts
//  per week or month, the commonest values, optionally what came before,
//  and then every record. Built from the same queries as everything else;
//  `Report.markdown` sets it as text (and `press` sets that as a PDF).
//

import Foundation

public extension RecordStore {

    /// Assembles a report of `collection`.
    func report(_ collection: String, _ spec: ReportSpec) throws(RecordStoreError) -> Report {
        let schema = try schema(named: collection)
        let dateField = try? QueryPlanning.dateField(schema, named: spec.dateField)
        if spec.dateField != nil, dateField == nil { _ = try QueryPlanning.dateField(schema, named: spec.dateField) }

        // The period: given, or the last N days/weeks/months up to today.
        var since = spec.since, until = spec.until
        if let last = spec.last {
            guard since == nil, until == nil else { throw .invalidQuery("give a period by last, or by since and until — not both") }
            let today = now()
            since = localDay(try DurationParsing.periodStart(last, endingOn: today, timeZone: timeZone), fallback: "")
            until = localDay(today, fallback: "")
        }
        if (since != nil || until != nil) && dateField == nil {
            throw .invalidQuery("\(collection) has no date field, so a report of it has no period")
        }
        let base = Query(filters: spec.filters, since: since, until: until, dateField: dateField?.name)
        let records = try self.records(collection, base)

        var from = try since.map { (text: String) throws(RecordStoreError) -> String in try day(text) }
        var to = try until.map { (text: String) throws(RecordStoreError) -> String in try day(text) }
        if let dateField {
            let days = records.compactMap { record -> String? in
                guard case .string(let value)? = record.values[dateField.name] else { return nil }
                return dateField.type == .datetime ? localDay(DateParsing.instant(value), fallback: value) : value
            }.sorted()
            if from == nil { from = days.first }
            if to == nil { to = days.last }
        }

        var sections: [Report.Section] = []
        let totals = spec.averages.map(Aggregate.average) + spec.sums.map(Aggregate.sum)

        // Overall.
        if !records.isEmpty {
            var overall = try query(collection, Query(filters: base.filters, since: since, until: until, dateField: dateField?.name,
                                                      aggregates: [.count] + totals))
            overall.columns = overall.columns.map { $0 == "count" ? "records" : $0 }
            overall.rows = overall.rows.map { row in
                var row = row
                row["records"] = row.removeValue(forKey: "count")
                return row
            }
            sections.append(Report.Section(title: "Overall", table: overall))
        }

        // Per week or month.
        if let dateField, !records.isEmpty {
            let period = spec.every ?? defaultPeriod(from: from, to: to)
            let buckets = try query(collection, Query(filters: base.filters, since: since, until: until, dateField: dateField.name,
                                                      aggregates: [.count] + totals, groupBy: [.period(period)]))
            sections.append(Report.Section(title: period == .week ? "By week" : "By \(period.rawValue)", table: buckets))
        }

        // The commonest values.
        for path in spec.top where !records.isEmpty {
            var top = try query(collection, Query(filters: base.filters, since: since, until: until, dateField: dateField?.name,
                                                  aggregates: [.count], groupBy: [.field(path)],
                                                  order: [Ordering(key: "count", descending: true)], limit: spec.topLimit ?? 10))
            top.columns.append("share")
            top.rows = top.rows.map { row in
                var row = row
                if case .number(let n)? = row["count"] {
                    row["share"] = .string(percent(DecimalMath.ratio(Int(truncating: NSDecimalNumber(decimal: n)), records.count, places: 3)))
                }
                return row
            }
            sections.append(Report.Section(title: "Most common \(path.replacingOccurrences(of: "_", with: " "))",
                                           note: "Share of the \(records.count) records; a record can count under several.", table: top))
        }

        // What came before.
        if let window = spec.window, !records.isEmpty {
            let analysis = try self.window(WindowSpec(events: collection, filters: base.filters, dateField: dateField?.name,
                                                      exposures: window.exposures, exposureFilters: window.exposureFilters,
                                                      exposureDateField: window.exposureDateField, since: since, until: until,
                                                      within: window.within, tally: window.tally, minEvents: window.minEvents))
            var table = analysis.table
            let shown = ["value", "events", "events_share", "matched_share", "all_share", "ratio"]
            table.columns = (window.tally.count > 1 ? ["field"] : []) + shown
            table.rows = table.rows.map { row in
                var row = row
                for column in ["events_share", "matched_share", "all_share"] {
                    if case .number(let share)? = row[column] { row[column] = .string(percent(share)) }
                }
                return row
            }
            let them = window.exposures.replacingOccurrences(of: "_", with: " ")
            let note = """
                \(analysis.covered) of \(analysis.events) records had \(them) in the window before them \
                (\(window.within.text)); \(analysis.matched) of the \(analysis.exposures) \(them) in the period fell in a window. \
                The ratio is the share of \(them) before records that had the value over its share of all \(them): \
                near 1 means the value is merely common. This shows what came before, not what caused it.
                """
            let headings = ["field": "field", "value": window.tally.count == 1 ? window.tally[0].replacingOccurrences(of: "_", with: " ") : "value",
                            "events": "records after", "events_share": "share of records",
                            "matched_share": "share of \(them) before", "all_share": "share of all \(them)", "ratio": "ratio"]
            sections.append(Report.Section(title: "What came before", note: note, table: table, headings: headings))
        }

        // The log.
        let columns = spec.columns.isEmpty
            ? (dateField.map { [$0.name] } ?? []) + schema.fields.map(\.name).filter { $0 != dateField?.name }
            : spec.columns
        for name in columns where schema.field(name) == nil { throw .unknownField(collection: collection, field: name) }
        let ordered = dateField.map { field in
            records.sorted { ValueDisplay.text($0.values[field.name] ?? .null) < ValueDisplay.text($1.values[field.name] ?? .null) }
        } ?? records
        let log = ResultTable(columns: columns, rows: ordered.map { record in
            var row: [String: JSONValue] = [:]
            for name in columns {
                let value = record.values[name] ?? .null
                if schema.field(name)?.type == .datetime, case .string(let text) = value {
                    row[name] = .string(localMinute(text))
                } else {
                    row[name] = value
                }
            }
            return row
        })
        sections.append(Report.Section(title: "Log", note: records.isEmpty ? "No records in this period." : nil, table: log))

        return Report(title: spec.title ?? collection.replacingOccurrences(of: "_", with: " ").capitalized,
                      collection: collection, from: from, to: to, count: records.count, generatedAt: timestamp(),
                      notes: spec.notes, sections: sections)
    }

    /// Runs a report saved with the collection.
    func report(_ collection: String, saved name: String) throws(RecordStoreError) -> Report {
        guard let spec = try schema(named: collection).reports?.first(where: { $0.name == name }) else {
            throw .invalidQuery("\(collection) has no saved report \"\(name)\"")
        }
        return try report(collection, spec)
    }
}

extension RecordStore {

    /// A since/until as a day.
    private func day(_ text: String) throws(RecordStoreError) -> String {
        do throws(DateFailure) { return try DateParsing.date(text, now: now(), timeZone: timeZone) } catch {
            throw .invalidQuery(error.reason)
        }
    }

    /// The local day of an instant, `YYYY-MM-DD`.
    func localDay(_ instant: Date?, fallback: String) -> String {
        guard let instant else { return String(fallback.prefix(10)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// A stored UTC datetime as local `YYYY-MM-DD HH:MM`, for people.
    func localMinute(_ stored: String) -> String {
        guard let instant = DateParsing.instant(stored) else { return stored }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        return String(format: "%04d-%02d-%02d %02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
    }

    private func defaultPeriod(from: String?, to: String?) -> Grouping.Period {
        guard let from, let to, let a = DateParsing.instant(from + "T00:00:00Z"), let b = DateParsing.instant(to + "T00:00:00Z") else {
            return .month
        }
        return b.timeIntervalSince(a) < 70 * 86_400 ? .week : .month
    }

    private func percent(_ share: Decimal?) -> String {
        guard let share else { return "" }
        return "\(NSDecimalNumber(decimal: DecimalMath.rounded(share * 100, places: 0)).stringValue)%"
    }
}
