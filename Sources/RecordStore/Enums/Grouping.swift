//
//  Grouping.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a query groups its aggregates by.
public enum Grouping: Hashable, Codable, Sendable {

    /// The values of one field.
    case field(String)

    /// Calendar periods of the query's date field.
    case period(Period)

    /// A calendar period.
    public enum Period: String, Codable, Sendable, CaseIterable {
        case day, week, month, year
    }
}
