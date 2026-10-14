//
//  DurationParsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Spans of time as people write them: `30m`, `3h`, `1.5h`, `2d`, `90min`,
//  and windows `30m..3h` (the low end borrows the high end's unit when it
//  has none: `0..3h`). Periods for reports: `90d`, `12w`, `6m`, `1y`.
//

import Foundation

enum DurationParsing {

    /// Seconds in one unit, by every spelling accepted.
    static func unitSeconds(_ unit: String) -> Double? {
        switch unit.lowercased() {
        case "s", "sec", "secs", "second", "seconds": return 1
        case "m", "min", "mins", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hour", "hours": return 3600
        case "d", "day", "days": return 86_400
        case "w", "wk", "week", "weeks": return 604_800
        default: return nil
        }
    }

    /// `30m` → 1800. A bare number takes `defaultUnit` seconds, or is refused.
    static func seconds(_ text: String, defaultUnit: Double? = nil) throws(RecordStoreError) -> Double {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard let m = raw.wholeMatch(of: /(\d+(?:\.\d+)?)\s*([a-zA-Z]*)/), let amount = Double(m.1) else {
            throw .invalidQuery("\"\(text)\" is not a span of time — write 30m, 3h or 2d")
        }
        let unit = String(m.2)
        if unit.isEmpty {
            guard let defaultUnit else { throw .invalidQuery("\"\(text)\" needs a unit — 30m, 3h or 2d") }
            return amount * defaultUnit
        }
        guard let size = unitSeconds(unit) else { throw .invalidQuery("\"\(unit)\" is not a unit of time — s, m, h, d or w") }
        return amount * size
    }

    /// `30m..3h` → (1800, 10800); `3h` → (0, 10800).
    static func window(_ text: String) throws(RecordStoreError) -> (Double, Double) {
        let parts = text.components(separatedBy: "..")
        switch parts.count {
        case 1:
            return (0, try seconds(parts[0]))
        case 2:
            let high = try seconds(parts[1])
            let unit = parts[1].trimmingCharacters(in: .whitespaces).firstMatch(of: /[a-zA-Z]+$/).map { String($0.0) }
            let low = try seconds(parts[0], defaultUnit: unit.flatMap(unitSeconds))
            guard low <= high else { throw .invalidQuery("the window \(text) starts after it ends") }
            return (low, high)
        default:
            throw .invalidQuery("\"\(text)\" is not a window — write 30m..3h")
        }
    }

    /// Whether `text` reads as a window rather than a field path.
    static func isWindow(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).first?.isNumber ?? false
    }

    /// The first day of a period of `text` (`90d`, `12w`, `6m`, `1y`) ending on `day`.
    static func periodStart(_ text: String, endingOn day: Date, timeZone: TimeZone) throws(RecordStoreError) -> Date {
        guard let m = text.trimmingCharacters(in: .whitespaces).lowercased().wholeMatch(of: /(\d+)\s*(d|days?|w|weeks?|m|months?|y|years?)/),
              let n = Int(m.1), n > 0 else {
            throw .invalidQuery("\"\(text)\" is not a period — write 90d, 12w, 6m or 1y")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let component: Calendar.Component
        switch m.2.first {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        default: component = .year
        }
        let back = calendar.date(byAdding: component, value: -n, to: day) ?? day
        return calendar.date(byAdding: .day, value: 1, to: back) ?? back
    }
}

extension DurationParsing {

    /// 1800 → `30m`, 10800 → `3h`, 5400 → `90m`.
    static func describe(_ seconds: Double) -> String {
        // Hours up to three days: "0..24h" reads back as written, not "0..1d".
        let units: [(Double, String)] = seconds < 3 * 86_400 ? [(3600, "h"), (60, "m")] : [(86_400, "d"), (3600, "h"), (60, "m")]
        for (size, unit) in units where seconds >= size && seconds.truncatingRemainder(dividingBy: size) == 0 {
            return "\(Int(seconds / size))\(unit)"
        }
        if seconds == 0 { return "0" }
        return seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60))m" : "\(Int(seconds))s"
    }

    static func unitName(_ seconds: Double) -> String {
        switch seconds {
        case 1: return "seconds"
        case 60: return "minutes"
        case 3600: return "hours"
        case 86_400: return "days"
        case 604_800: return "weeks"
        default: return "×\(Int(seconds))s"
        }
    }
}
