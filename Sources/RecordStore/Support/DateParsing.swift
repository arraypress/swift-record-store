//
//  DateParsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Dates in, ISO strings out. Stored dates are text that sorts the way time
//  does — `YYYY-MM-DD`, and datetimes as UTC `YYYY-MM-DDTHH:MM:SSZ` — so
//  range filters and period buckets are plain string comparisons.
//
//  Fixed-width parsing, no shared DateFormatter. Slash dates with the day
//  first or the month first ("03/04/2026") are REFUSED: which one a receipt
//  meant is not something to guess.
//

import Foundation

enum DateParsing {

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// A calendar date as `YYYY-MM-DD`.
    static func date(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws(DateFailure) -> String {
        let raw = text.trimmingCharacters(in: .whitespaces)
        let lower = raw.lowercased()

        if let offset = ["yesterday": -1, "today": 0, "tomorrow": 1][lower] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let day = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return format(parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        if let m = raw.wholeMatch(of: /(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})/) {
            return try checked(Int(m.1)!, Int(m.2)!, Int(m.3)!, raw)
        }
        if let m = raw.wholeMatch(of: /(\d{4})(\d{2})(\d{2})/) {
            return try checked(Int(m.1)!, Int(m.2)!, Int(m.3)!, raw)
        }
        // An ISO datetime: the date as written, before any offset.
        if let m = raw.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})[T ]\d{2}:\d{2}/) {
            return try checked(Int(m.1)!, Int(m.2)!, Int(m.3)!, raw)
        }
        // "13 Oct 2026", "13 October 2026"
        if let m = lower.wholeMatch(of: /(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)\.?,?\s+(\d{4})/), let month = month(String(m.2)) {
            return try checked(Int(m.3)!, month, Int(m.1)!, raw)
        }
        // "Oct 13 2026", "October 13, 2026"
        if let m = lower.wholeMatch(of: /([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})/), let month = month(String(m.1)) {
            return try checked(Int(m.3)!, month, Int(m.2)!, raw)
        }
        if let m = raw.wholeMatch(of: /(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})/) {
            let a = Int(m.1)!, b = Int(m.2)!, year = Int(m.3)!
            // Unambiguous only when one side cannot be a month.
            if a > 12, b <= 12 { return try checked(year, b, a, raw) }
            if b > 12, a <= 12 { return try checked(year, a, b, raw) }
            if a == b { return try checked(year, a, b, raw) }
            throw .ambiguous(raw)
        }
        throw .unreadable(raw)
    }

    /// An instant as UTC `YYYY-MM-DDTHH:MM:SSZ`. Text without an offset is
    /// read in `timeZone`.
    static func datetime(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws(DateFailure) -> String {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if raw.lowercased() == "now" { return utc(now) }
        let pattern = /(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|[+\-]\d{2}:?\d{2})?/
        guard let m = raw.wholeMatch(of: pattern) else {
            // A bare date is midnight of that day.
            let day = try date(raw, now: now, timeZone: timeZone)
            return try datetime(day + "T00:00:00", now: now, timeZone: timeZone)
        }
        let year = Int(m.1)!, month = Int(m.2)!, day = Int(m.3)!
        let hour = Int(m.4)!, minute = Int(m.5)!, second = m.6.map { Int($0)! } ?? 0
        _ = try checked(year, month, day, raw)
        guard hour < 24, minute < 60, second < 61 else { throw .unreadable(raw) }

        var zone = timeZone
        if let offset = m.7 {
            if offset == "Z" {
                zone = TimeZone(secondsFromGMT: 0)!
            } else {
                let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
                let seconds = (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60) * (offset.hasPrefix("-") ? -1 : 1)
                guard let fixed = TimeZone(secondsFromGMT: seconds) else { throw .unreadable(raw) }
                zone = fixed
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let instant = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else {
            throw .unreadable(raw)
        }
        return utc(instant)
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` for an instant.
    static func utc(_ instant: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        return format(p.year!, p.month!, p.day!)
            + "T" + pad(p.hour!) + ":" + pad(p.minute!) + ":" + pad(p.second!) + "Z"
    }

    private static func month(_ name: String) -> Int? {
        guard name.count >= 3 else { return nil }
        return months.firstIndex(of: String(name.prefix(3))).map { $0 + 1 }
    }

    private static func checked(_ year: Int, _ month: Int, _ day: Int, _ raw: String) throws(DateFailure) -> String {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1, day <= daysIn(month, year) else {
            throw .invalid(raw)
        }
        return format(year, month, day)
    }

    private static func daysIn(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func format(_ year: Int, _ month: Int, _ day: Int) -> String {
        String(repeating: "0", count: max(0, 4 - String(year).count)) + String(year) + "-" + pad(month) + "-" + pad(day)
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

/// Why a date was refused.
enum DateFailure: Error, Equatable {
    case unreadable(String)
    case ambiguous(String)
    case invalid(String)

    var reason: String {
        switch self {
        case .unreadable(let raw): return "\"\(raw)\" is not a date — write YYYY-MM-DD"
        case .ambiguous(let raw): return "\"\(raw)\" could be day-first or month-first — write YYYY-MM-DD"
        case .invalid(let raw): return "\"\(raw)\" is not a real calendar date"
        }
    }
}
