//
//  WindowMath.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  The arithmetic of "what came before", apart from any database: events
//  with windows, exposures with times and values, and for each value how
//  often it falls inside a window against how often it turns up at all.
//
//  The ratio is the point. Counting alone ranks whatever is commonest
//  first — an allergen in every meal precedes every symptom — so each value
//  is measured twice: its share of the exposures inside windows, and its
//  share of every exposure in the period. Their ratio is near 1 for a value
//  that is merely common, and above 1 for one that turns up before events
//  more than it turns up in general. It is co-occurrence, not cause.
//

import Foundation

enum WindowMath {

    struct Event {
        var id: Int64
        var time: Date
        /// Seconds before the event: (from, to). Nil when it has no window.
        var window: (from: Double, to: Double)?
    }

    struct Exposure {
        var id: Int64
        var time: Date
    }

    struct Result {
        var covered: Int
        var skipped: Int
        var matched: Int
        var table: ResultTable
    }

    static let columns = ["field", "value", "events", "events_share", "matched", "matched_share", "all", "all_share", "ratio"]

    /// `values[field][exposure id]` lists the values each exposure has.
    static func analyse(events: [Event], exposures: [Exposure], tally: [String],
                        values: [String: [Int64: [JSONValue]]], minEvents: Int) -> Result {
        let sorted = exposures.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        let times = sorted.map(\.time)
        var covered = 0, skipped = 0
        var windows: [Set<Int64>] = []
        var matched = Set<Int64>()
        for event in events {
            guard let window = event.window else { skipped += 1; continue }
            let low = event.time.addingTimeInterval(-window.to), high = event.time.addingTimeInterval(-window.from)
            var index = firstIndex(in: times, notBefore: low)
            var inside = Set<Int64>()
            while index < sorted.count, sorted[index].time <= high {
                inside.insert(sorted[index].id)
                index += 1
            }
            if !inside.isEmpty { covered += 1; windows.append(inside); matched.formUnion(inside) }
        }

        var rows: [[String: JSONValue]] = []
        for field in tally {
            let byExposure = values[field] ?? [:]
            // Values are told apart without regard to case; each is shown as
            // first written (by the earliest exposure).
            var spelling: [String: JSONValue] = [:]
            var holders: [String: Set<Int64>] = [:]
            for exposure in sorted {
                for value in byExposure[exposure.id] ?? [] where value != .null {
                    let key = ValueDisplay.text(value).lowercased()
                    if spelling[key] == nil { spelling[key] = value }
                    holders[key, default: []].insert(exposure.id)
                }
            }
            for (key, ids) in holders {
                let eventCount = windows.filter { !$0.isDisjoint(with: ids) }.count
                guard eventCount >= max(1, minEvents) else { continue }
                let inWindows = ids.intersection(matched).count
                let matchedShare = DecimalMath.ratio(inWindows, matched.count, places: 3)
                let allShare = DecimalMath.ratio(ids.count, sorted.count, places: 3)
                var ratio: JSONValue = .null
                if matched.count > 0, !sorted.isEmpty {
                    let exact = (Decimal(inWindows) / Decimal(matched.count)) / (Decimal(ids.count) / Decimal(sorted.count))
                    ratio = .number(DecimalMath.rounded(exact, places: 2))
                }
                rows.append([
                    "field": .string(field), "value": spelling[key] ?? .null,
                    "events": .number(Decimal(eventCount)),
                    "events_share": DecimalMath.ratio(eventCount, covered, places: 3).map(JSONValue.number) ?? .null,
                    "matched": .number(Decimal(inWindows)),
                    "matched_share": matchedShare.map(JSONValue.number) ?? .null,
                    "all": .number(Decimal(ids.count)),
                    "all_share": allShare.map(JSONValue.number) ?? .null,
                    "ratio": ratio,
                ])
            }
        }
        rows = Accumulation.sorted(rows, by: [Ordering(key: "ratio", descending: true), Ordering(key: "events", descending: true),
                                             Ordering(key: "field"), Ordering(key: "value")])
        return Result(covered: covered, skipped: skipped, matched: matched.count, table: ResultTable(columns: columns, rows: rows))
    }

    /// The first index whose time is at or after `time` (times sorted).
    private static func firstIndex(in times: [Date], notBefore time: Date) -> Int {
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
