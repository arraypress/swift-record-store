//
//  JournalEntry.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One write, as the undo journal remembers it.
public struct JournalEntry: Sendable, Equatable {

    public var id: Int64

    /// UTC ISO 8601.
    public var at: String

    public var collection: String

    public var action: JournalAction

    /// The record touched, for inserts, updates and deletes.
    public var recordID: Int64?

    /// A one-line account, e.g. `added field notes (text)`.
    public var summary: String

    /// Whether it has been undone. An undone entry cannot be undone again.
    public var undone: Bool

    /// Entries written by one operation — an import, a forced delete and
    /// the links it removed — share a batch (the first entry's id), and
    /// undo reverses the whole batch. `nil` for a write on its own.
    public var batch: Int64?

    public init(id: Int64, at: String, collection: String, action: JournalAction, recordID: Int64?, summary: String, undone: Bool,
                batch: Int64? = nil) {
        self.id = id
        self.at = at
        self.collection = collection
        self.action = action
        self.recordID = recordID
        self.summary = summary
        self.undone = undone
        self.batch = batch
    }
}
