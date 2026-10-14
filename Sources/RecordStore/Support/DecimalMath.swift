//
//  DecimalMath.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Decimal helpers Foundation leaves out.
enum DecimalMath {

    /// Whether a decimal has no fractional part.
    static func isWhole(_ value: Decimal) -> Bool {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded == value
    }

    /// `numerator / denominator` rounded to `places`, or nil when dividing by zero.
    static func ratio(_ numerator: Int, _ denominator: Int, places: Int) -> Decimal? {
        guard denominator != 0 else { return nil }
        return rounded(Decimal(numerator) / Decimal(denominator), places: places)
    }

    static func rounded(_ value: Decimal, places: Int) -> Decimal {
        var input = value
        var out = Decimal()
        NSDecimalRound(&out, &input, places, .plain)
        return out
    }
}
