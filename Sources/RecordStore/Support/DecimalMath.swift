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
}
