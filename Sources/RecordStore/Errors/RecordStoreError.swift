//
//  RecordStoreError.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Everything the store can refuse or fail at.
public enum RecordStoreError: Error, Sendable, Equatable {

    /// A schema or schema change that cannot be accepted.
    case invalidSchema(String)

    /// No collection by that name.
    case unknownCollection(String)

    /// The collection has no such field.
    case unknownField(collection: String, field: String)

    /// A value that does not fit its field.
    case invalidValue(field: String, reason: String)

    /// Several records in a batch did not fit; nothing was stored.
    case invalidRecords([String])

    /// A query that cannot be run as written.
    case invalidQuery(String)

    /// Input that is not JSON.
    case unreadableJSON(String)

    /// The record would duplicate one already stored.
    case duplicate(String)

    /// No record with that id.
    case recordNotFound(collection: String, id: Int64)

    /// Nothing to undo, or an entry that can no longer be undone safely.
    case cannotUndo(String)

    /// A statement tried to write through the read-only connection.
    case readOnly(String)

    /// SQLite or the file system failed.
    case storage(String)
}
