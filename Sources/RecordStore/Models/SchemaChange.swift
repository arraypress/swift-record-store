//
//  SchemaChange.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// An explicit change to a collection's shape.
public enum SchemaChange: Sendable, Equatable {

    /// A new field. Free: existing records get its default, or nothing.
    case addField(Field)

    /// A new name for a field; values are kept.
    case renameField(from: String, to: String)

    /// Removes a field and its values. Undo puts them back.
    case dropField(String)

    /// Makes a text field the collection's key (every record must have a
    /// distinct one), or — with `nil` — stops naming records by key.
    case setKey(String?)

    /// Saves a report spec with the collection, replacing one of the same name.
    case saveReport(ReportSpec)

    /// Removes a saved report spec.
    case removeReport(String)
}
