//
//  Filter.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One condition a record must meet.
public struct Filter: Codable, Sendable, Equatable {

    /// A field name, or `id`.
    public var field: String

    public var op: FilterOperator

    /// The value as written; it is read as the field's type.
    public var value: String

    public init(field: String, op: FilterOperator, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }
}
