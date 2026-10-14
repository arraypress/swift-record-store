//
//  WindowSpec.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What came before: for each record of one collection (the events — a
/// symptom log), the records of another (the exposures — meals) whose time
/// falls in a window before it, and how often each value of the exposures'
/// fields turns up there compared with how often it turns up at all.
///
/// The answer is co-occurrence, never cause: a value common in the windows
/// is only worth a look when it is commoner there than in every exposure.
public struct WindowSpec: Codable, Sendable, Equatable {

    /// The collection whose records open a window (each needs a datetime).
    public var events: String

    /// Conditions on the events.
    public var filters: [Filter]

    /// The events' datetime field; defaults to its only one.
    public var dateField: String?

    /// The collection searched for records inside the windows.
    public var exposures: String

    /// Conditions on the exposures.
    public var exposureFilters: [Filter]

    /// The exposures' datetime field; defaults to its only one.
    public var exposureDateField: String?

    /// The period, inclusive, applied to both collections by their own
    /// datetime fields.
    public var since: String?
    public var until: String?

    /// How far before each event to look.
    public var within: Window

    /// The exposures' fields to count: tags, links, choices, text, a whole
    /// number or yes/no — or a path through a link (`foods.category`).
    public var tally: [String]

    /// Leave out values seen before fewer events than this.
    public var minEvents: Int

    public init(events: String, filters: [Filter] = [], dateField: String? = nil, exposures: String,
                exposureFilters: [Filter] = [], exposureDateField: String? = nil, since: String? = nil,
                until: String? = nil, within: Window, tally: [String], minEvents: Int = 1) {
        self.events = events
        self.filters = filters
        self.dateField = dateField
        self.exposures = exposures
        self.exposureFilters = exposureFilters
        self.exposureDateField = exposureDateField
        self.since = since
        self.until = until
        self.within = within
        self.tally = tally
        self.minEvents = minEvents
    }

    /// A window before an event.
    public enum Window: Codable, Sendable, Equatable {

        /// The same for every event: from `from` to `to` seconds before it.
        case fixed(from: Double, to: Double)

        /// Each event's own, read from a range field of the event — or of a
        /// record it links to (`symptom.onset_hours`) — in `unit`
        /// seconds (3600 for hours). Through a list of links, the widest.
        case field(String, unit: Double)
    }
}
