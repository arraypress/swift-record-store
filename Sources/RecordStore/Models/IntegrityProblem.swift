//
//  IntegrityProblem.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One thing `check` found wrong in a database.
public struct IntegrityProblem: Codable, Sendable, Equatable {

    /// The collection the problem is in.
    public var collection: String

    /// The record: its key, or `#id`. Empty for a problem with the file.
    public var record: String

    /// The field involved, if any.
    public var field: String?

    /// What is wrong, in a sentence.
    public var problem: String

    public init(collection: String, record: String, field: String?, problem: String) {
        self.collection = collection
        self.record = record
        self.field = field
        self.problem = problem
    }
}
