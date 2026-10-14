//
//  WindowSpec+Parsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension WindowSpec.Window {

    /// `30m..3h` (or `3h`, meaning 0..3h) is a fixed window; anything else is
    /// the path to a range field, read in `unit` (hours unless given).
    static func parse(_ text: String, unit: String = "h") throws(RecordStoreError) -> WindowSpec.Window {
        if DurationParsing.isWindow(text) {
            let (from, to) = try DurationParsing.window(text)
            return .fixed(from: from, to: to)
        }
        guard let seconds = DurationParsing.unitSeconds(unit) else {
            throw .invalidQuery("\"\(unit)\" is not a unit of time — s, m, h, d or w")
        }
        let path = text.trimmingCharacters(in: .whitespaces)
        guard path.wholeMatch(of: /[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*/) != nil else {
            throw .invalidQuery("\"\(text)\" is neither a window (30m..3h) nor a field path (symptom.onset_hours)")
        }
        return .field(path, unit: seconds)
    }

    /// How a person would write it back.
    var text: String {
        switch self {
        case .fixed(let from, let to): return "\(DurationParsing.describe(from))..\(DurationParsing.describe(to))"
        case .field(let path, let unit): return "\(path) (\(DurationParsing.unitName(unit)))"
        }
    }
}
