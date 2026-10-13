//
//  Aggregate.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A summary computed over the records a query matches.
public enum Aggregate: Hashable, Codable, Sendable {
    case count
    case sum(String)
    case average(String)
    case minimum(String)
    case maximum(String)
}
