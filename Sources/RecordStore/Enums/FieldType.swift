//
//  FieldType.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a field holds. Small on purpose: these cover receipts, workouts,
/// mileage, habits, reading lists and linked catalogues without a type
/// system to maintain.
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

    /// A link to one record of another collection (its ``Field/target``):
    /// stored as that record's key, or its id when the target has no key.
    /// A value that names no record is refused.
    case ref

    /// Links to several records of another collection, stored like tags:
    /// a JSON array of keys (or ids).
    case refs

    /// A pair of numbers, low to high — `[0.5, 3]`, `"0.5..3"` — stored as
    /// two REAL columns (`<field>` and `<field>__max`).
    case range
}
