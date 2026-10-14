//
//  ReportSpec.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a report of one collection says. Saved with the schema under a
/// `name`, it can be run again with nothing but that name.
public struct ReportSpec: Codable, Sendable, Equatable {

    /// The name it is saved under.
    public var name: String?

    /// The heading; the collection's name when empty.
    public var title: String?

    /// Conditions on the records.
    public var filters: [Filter]

    /// The period, inclusive. `last` (`90d`, `12w`, `6m`, `1y`) is a period
    /// ending today instead — what a saved report usually wants.
    public var since: String?
    public var until: String?
    public var last: String?

    /// The date field the period and buckets use.
    public var dateField: String?

    /// The bucket for the counts table: week or month (default: month,
    /// or week when the period is under ten weeks).
    public var every: Grouping.Period?

    /// Number fields averaged per bucket and overall.
    public var averages: [String]

    /// Number or money fields summed per bucket and overall.
    public var sums: [String]

    /// Fields (or paths through links) whose most common values get a table.
    public var top: [String]

    /// Rows in each top table (default 10).
    public var topLimit: Int?

    /// The fields in the log, in order (default: every field).
    public var columns: [String]

    /// A "what came before" section (see ``WindowSpec``).
    public var window: ReportWindow?

    /// A paragraph under the title.
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case name, title, filters, since, until, last, dateField, every, averages, sums, top, topLimit, columns, window, notes
    }

    public init(name: String? = nil, title: String? = nil, filters: [Filter] = [], since: String? = nil, until: String? = nil,
                last: String? = nil, dateField: String? = nil, every: Grouping.Period? = nil, averages: [String] = [],
                sums: [String] = [], top: [String] = [], topLimit: Int? = nil, columns: [String] = [],
                window: ReportWindow? = nil, notes: String? = nil) {
        self.name = name
        self.title = title
        self.filters = filters
        self.since = since
        self.until = until
        self.last = last
        self.dateField = dateField
        self.every = every
        self.averages = averages
        self.sums = sums
        self.top = top
        self.topLimit = topLimit
        self.columns = columns
        self.window = window
        self.notes = notes
    }

    /// A ``WindowSpec`` whose events are the report's own records.
    public struct ReportWindow: Codable, Sendable, Equatable {
        public var exposures: String
        public var exposureFilters: [Filter]
        public var exposureDateField: String?
        public var within: WindowSpec.Window
        public var tally: [String]
        public var minEvents: Int

        enum CodingKeys: String, CodingKey {
            case exposures, exposureFilters, exposureDateField, within, tally, minEvents
        }

        public init(exposures: String, exposureFilters: [Filter] = [], exposureDateField: String? = nil,
                    within: WindowSpec.Window, tally: [String], minEvents: Int = 2) {
            self.exposures = exposures
            self.exposureFilters = exposureFilters
            self.exposureDateField = exposureDateField
            self.within = within
            self.tally = tally
            self.minEvents = minEvents
        }
    }
}
