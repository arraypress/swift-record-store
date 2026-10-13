//
//  Query.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What to fetch or summarise from a collection.
public struct Query: Sendable, Equatable {

    /// All must hold.
    public var filters: [Filter]

    /// Inclusive bounds on the date field, `YYYY-MM-DD` or anything a date
    /// field accepts.
    public var since: String?
    public var until: String?

    /// The date or datetime field that `since`, `until`, periods and running
    /// totals use. Defaults to the schema's only one.
    public var dateField: String?

    /// Summaries; empty lists records instead.
    public var aggregates: [Aggregate]

    /// What aggregates are grouped by.
    public var groupBy: [Grouping]

    /// A field to accumulate: over records in date order, or over groups.
    public var running: String?

    public var order: [Ordering]

    public var limit: Int?

    public init(
        filters: [Filter] = [],
        since: String? = nil,
        until: String? = nil,
        dateField: String? = nil,
        aggregates: [Aggregate] = [],
        groupBy: [Grouping] = [],
        running: String? = nil,
        order: [Ordering] = [],
        limit: Int? = nil
    ) {
        self.filters = filters
        self.since = since
        self.until = until
        self.dateField = dateField
        self.aggregates = aggregates
        self.groupBy = groupBy
        self.running = running
        self.order = order
        self.limit = limit
    }
}
