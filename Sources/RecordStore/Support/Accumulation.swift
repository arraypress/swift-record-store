//
//  Accumulation.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  The arithmetic after SQL: aggregate cells into output values, running
//  totals (per currency for money — a GBP running total never absorbs a EUR
//  row), and sorting result rows by any column.
//

import Foundation

enum Accumulation {

    /// One aggregate cell as output JSON.
    static func aggregateValue(_ raw: Database.Row, alias: String, field: Field?, kind: String) -> JSONValue {
        let value = raw[alias]
        guard let field else { return ValueCoercion.raw(value) }
        if value == .null { return .null }

        if field.type == .money {
            guard case .text(let currency) = raw["c_\(field.name)"] else { return .null }
            let minor: Int64
            switch value {
            case .int(let i): minor = i
            case .real(let d): minor = Int64(d)
            default: return .null
            }
            if kind == "avg" {
                guard case .int(let n) = raw[alias + "_n"] else { return .null }
                return MoneyParsing.json(MoneyParsing.average(minor, count: Int(n), currency: currency))
            }
            return MoneyParsing.json(Money(minorUnits: minor, currency: currency))
        }
        if kind == "avg" {
            guard case .int(let n) = raw[alias + "_n"], n > 0 else { return .null }
            let total: Decimal
            switch value {
            case .int(let i): total = Decimal(i)
            case .real(let d): total = ValueCoercion.decimal(d)
            default: return .null
            }
            var quotient = total / Decimal(n)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &quotient, 6, .plain)
            return .number(rounded)
        }
        return ValueCoercion.raw(value)
    }

    /// Adds a running-total column, in row order.
    static func running(_ rows: [[String: JSONValue]], source: String, into name: String, money: Bool) -> [[String: JSONValue]] {
        var totals: [String: Int64] = [:]
        var number = Decimal(0)
        return rows.map { row in
            var row = row
            let value = row[source] ?? .null
            if money {
                if case .object(let o) = value, case .string(let currency)? = o["currency"],
                   let parsed = try? MoneyParsing.parse(value, defaultCurrency: currency) {
                    totals[currency, default: 0] += parsed.minorUnits
                    row[name] = MoneyParsing.json(Money(minorUnits: totals[currency]!, currency: currency))
                } else {
                    row[name] = .null
                }
            } else {
                if case .number(let d) = value { number += d }
                row[name] = .number(number)
            }
            return row
        }
    }

    /// Rows sorted by the given keys; nulls last.
    static func sorted(_ rows: [[String: JSONValue]], by order: [Ordering]) -> [[String: JSONValue]] {
        rows.enumerated().sorted { a, b in
            for ordering in order {
                let left = a.element[ordering.key] ?? .null, right = b.element[ordering.key] ?? .null
                let comparison = compare(left, right)
                if comparison != .orderedSame {
                    if left == .null { return false }
                    if right == .null { return true }
                    return ordering.descending ? comparison == .orderedDescending : comparison == .orderedAscending
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func compare(_ a: JSONValue, _ b: JSONValue) -> ComparisonResult {
        switch (a, b) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedDescending
        case (_, .null): return .orderedAscending
        case (.number(let x), .number(let y)): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.string(let x), .string(let y)): return x.compare(y)
        case (.bool(let x), .bool(let y)): return x == y ? .orderedSame : (!x ? .orderedAscending : .orderedDescending)
        case (.object(let x), .object(let y)):
            guard case .string(let cx)? = x["currency"], case .string(let cy)? = y["currency"],
                  let mx = try? MoneyParsing.parse(a, defaultCurrency: cx),
                  let my = try? MoneyParsing.parse(b, defaultCurrency: cy) else { return .orderedSame }
            if cx != cy { return cx.compare(cy) }
            return mx.minorUnits == my.minorUnits ? .orderedSame : (mx.minorUnits < my.minorUnits ? .orderedAscending : .orderedDescending)
        default:
            return ValueDisplay.text(a).compare(ValueDisplay.text(b))
        }
    }
}
