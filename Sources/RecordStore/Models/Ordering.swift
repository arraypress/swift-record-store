//
//  Ordering.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A sort key.
public struct Ordering: Codable, Sendable, Equatable {

    /// A field name, `id`, or an aggregate column such as `total_sum`.
    public var key: String

    public var descending: Bool

    public init(key: String, descending: Bool = false) {
        self.key = key
        self.descending = descending
    }
}
