//
//  JSONValue.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A JSON value: what records go in as and come out as.
///
/// Numbers are `Decimal`, not `Double`, so `23.40` read from input is the
/// same `23.40` that reaches the money parser — a double would have made it
/// `23.399999999999999`.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
