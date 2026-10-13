//
//  ValueCoercion.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A field's value in (JSON → the columns it is stored in) and out (stored
//  columns → JSON). Every type's rules live here so add, update, filters
//  and defaults cannot disagree about what "a date" is.
//

import Foundation

enum ValueCoercion {

    /// The column values for a field, positionally matching
    /// ``SchemaRules/columns(of:)``.
    static func columns(for value: JSONValue, field: Field, now: Date, timeZone: TimeZone) throws(CoercionFailure) -> [Database.Value] {
        if value == .null {
            return field.type == .money ? [.null, .null] : [.null]
        }
        switch field.type {
        case .text:
            switch value {
            case .string(let s): return [.text(s)]
            case .number(let d): return [.text(NSDecimalNumber(decimal: d).stringValue)]
            case .bool(let b): return [.text(b ? "true" : "false")]
            default: throw .reason("expected text")
            }
        case .number:
            let decimal = try number(value)
            return [.real(NSDecimalNumber(decimal: decimal).doubleValue)]
        case .integer:
            let decimal = try number(value)
            guard DecimalMath.isWhole(decimal), let int = Int64(exactly: NSDecimalNumber(decimal: decimal)) else {
                throw .reason("expected a whole number")
            }
            return [.int(int)]
        case .money:
            do {
                let money = try MoneyParsing.parse(value, defaultCurrency: field.currency)
                return [.int(money.minorUnits), .text(money.currency)]
            } catch {
                throw .reason(error.reason)
            }
        case .date:
            guard case .string(let s) = value else { throw .reason("expected a date such as \"2026-10-13\"") }
            do { return [.text(try DateParsing.date(s, now: now, timeZone: timeZone))] } catch { throw .reason(error.reason) }
        case .datetime:
            guard case .string(let s) = value else { throw .reason("expected a datetime such as \"2026-10-13T09:30:00Z\"") }
            do { return [.text(try DateParsing.datetime(s, now: now, timeZone: timeZone))] } catch { throw .reason(error.reason) }
        case .bool:
            switch value {
            case .bool(let b): return [.int(b ? 1 : 0)]
            case .number(let d) where d == 0 || d == 1: return [.int(d == 1 ? 1 : 0)]
            case .string(let s):
                switch s.lowercased().trimmingCharacters(in: .whitespaces) {
                case "true", "yes", "y", "1": return [.int(1)]
                case "false", "no", "n", "0": return [.int(0)]
                default: break
                }
            default: break
            }
            throw .reason("expected true or false")
        case .choice:
            let text: String
            switch value {
            case .string(let s): text = s.trimmingCharacters(in: .whitespaces)
            case .number(let d): text = NSDecimalNumber(decimal: d).stringValue
            default: throw .reason("expected one of: \((field.choices ?? []).joined(separator: ", "))")
            }
            guard let match = (field.choices ?? []).first(where: { $0.lowercased() == text.lowercased() }) else {
                throw .reason("\"\(text)\" is not one of: \((field.choices ?? []).joined(separator: ", "))")
            }
            return [.text(match)]
        case .tags:
            var tags: [String]
            switch value {
            case .array(let items):
                tags = []
                for item in items {
                    guard case .string(let s) = item else { throw .reason("tags must be strings") }
                    tags.append(s)
                }
            case .string(let s): tags = s.split(separator: ",").map(String.init)
            default: throw .reason("expected a list of tags")
            }
            var seen = Set<String>()
            tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            return [.text(JSONCoding.text(.array(tags.map(JSONValue.string))))]
        }
    }

    /// A field's value read back from its stored columns.
    static func output(_ row: Database.Row, field: Field) -> JSONValue {
        let value = row[field.name]
        if value == .null { return .null }
        switch field.type {
        case .text, .date, .datetime, .choice:
            if case .text(let s) = value { return .string(s) }
        case .number:
            if case .real(let d) = value { return .number(decimal(d)) }
            if case .int(let i) = value { return .number(Decimal(i)) }
        case .integer:
            if case .int(let i) = value { return .number(Decimal(i)) }
        case .bool:
            if case .int(let i) = value { return .bool(i != 0) }
        case .money:
            if case .int(let minor) = value, case .text(let currency) = row[field.name + SchemaRules.currencySuffix] {
                return MoneyParsing.json(Money(minorUnits: minor, currency: currency))
            }
        case .tags:
            if case .text(let s) = value, let parsed = try? JSONCoding.parse(s) { return parsed }
        }
        return raw(value)
    }

    /// Any stored value as JSON, for raw SQL results.
    static func raw(_ value: Database.Value) -> JSONValue {
        switch value {
        case .null: return .null
        case .int(let i): return .number(Decimal(i))
        case .real(let d): return .number(decimal(d))
        case .text(let s): return .string(s)
        case .blob(let data): return .string(data.base64EncodedString())
        }
    }

    /// A double as the shortest decimal that round-trips, so 0.1 stays 0.1.
    static func decimal(_ value: Double) -> Decimal {
        Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    }

    private static func number(_ value: JSONValue) throws(CoercionFailure) -> Decimal {
        switch value {
        case .number(let d): return d
        case .string(let s):
            let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            if cleaned.wholeMatch(of: /[+\-]?(\d+\.?\d*|\.\d+)([eE][+\-]?\d+)?/) != nil,
               let d = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) { return d }
            throw .reason("\"\(s)\" is not a number")
        default: throw .reason("expected a number")
        }
    }
}

/// Why a value did not fit its field.
enum CoercionFailure: Error, Equatable {
    case reason(String)

    var reasonText: String {
        if case .reason(let text) = self { return text }
        return ""
    }
}

extension CoercionFailure {
    var reason: String { reasonText }
}
