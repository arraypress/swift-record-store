//
//  FieldType.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a field holds. Small on purpose: these cover receipts, workouts,
/// mileage, habits and reading lists without a type system to maintain.
public enum FieldType: String, Codable, Sendable, CaseIterable {

    /// Free text.
    case text

    /// A decimal number, stored as a double. Use ``money`` for amounts.
    case number

    /// A whole number.
    case integer

    /// An amount and a currency, stored as integer minor units — never a
    /// float, so sums are exact.
    case money

    /// A calendar date, `YYYY-MM-DD`.
    case date

    /// An instant, stored as UTC `YYYY-MM-DDTHH:MM:SSZ`.
    case datetime

    /// Yes or no.
    case bool

    /// One of a fixed list of values.
    case choice

    /// A list of short strings.
    case tags
}
