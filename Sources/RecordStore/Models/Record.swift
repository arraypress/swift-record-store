//
//  Record.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One stored record, as it comes back out.
public struct Record: Sendable, Equatable {

    /// Assigned on insert; never reused.
    public var id: Int64

    /// Field values by name, output-ready: money as `{amount, currency}`,
    /// dates as `YYYY-MM-DD`, tags as arrays.
    public var values: [String: JSONValue]

    /// Where it came from.
    public var provenance: Provenance

    /// When it was added, UTC ISO 8601.
    public var addedAt: String

    /// When it last changed, UTC ISO 8601.
    public var updatedAt: String?

    public init(id: Int64, values: [String: JSONValue], provenance: Provenance, addedAt: String, updatedAt: String? = nil) {
        self.id = id
        self.values = values
        self.provenance = provenance
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}
