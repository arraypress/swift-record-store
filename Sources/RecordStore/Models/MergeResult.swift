//
//  MergeResult.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What ``RecordStore/merge(_:into:provenance:)`` did with each record.
public struct MergeResult: Sendable, Equatable {

    /// Records whose key was new.
    public var added: [Record]

    /// Records whose key existed and whose given fields changed.
    public var updated: [Record]

    /// Keys that existed with every given field already as given.
    public var unchanged: [String]

    public init(added: [Record], updated: [Record], unchanged: [String]) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
    }
}
