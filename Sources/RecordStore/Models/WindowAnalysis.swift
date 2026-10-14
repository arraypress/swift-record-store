//
//  WindowAnalysis.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// The answer to a ``WindowSpec``.
///
/// Each row is one value of a tallied field: `events` (how many events had
/// it in their window), `matched` (exposures in any window that have it),
/// `matched_share` (of all exposures in windows), `all` and `all_share` (of
/// every exposure in the period), and `ratio` — `matched_share` over
/// `all_share`. A ratio near 1 is a value that is simply common; above 1 it
/// turns up before events more often than it turns up at all.
public struct WindowAnalysis: Sendable, Equatable {

    /// Events in the period that matched the filters.
    public var events: Int

    /// Events with at least one exposure in their window.
    public var covered: Int

    /// Events with no window (their range field was empty).
    public var skipped: Int

    /// Exposures in the period that matched the filters.
    public var exposures: Int

    /// Exposures inside at least one window.
    public var matched: Int

    /// One row per tallied value, highest ratio first.
    public var table: ResultTable

    public init(events: Int, covered: Int, skipped: Int, exposures: Int, matched: Int, table: ResultTable) {
        self.events = events
        self.covered = covered
        self.skipped = skipped
        self.exposures = exposures
        self.matched = matched
        self.table = table
    }
}
