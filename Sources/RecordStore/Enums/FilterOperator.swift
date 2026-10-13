//
//  FilterOperator.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// How a filter compares a field with its value.
public enum FilterOperator: String, Codable, Sendable, CaseIterable {
    case equal = "="
    case notEqual = "!="
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
    /// Text contains (case-insensitive); for tags, has the tag.
    case contains = "~"
    /// One of a comma-separated list.
    case oneOf = "in"
}
