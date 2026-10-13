//
//  Schema.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// The shape of a collection: its name and fields.
public struct Schema: Codable, Sendable, Equatable {

    /// The collection's name, which is also its table's.
    public var name: String

    /// The fields, in the order they are shown.
    public var fields: [Field]

    /// What the collection is for.
    public var description: String?

    /// Starts at 1 and goes up with every migration.
    public var version: Int

    public init(name: String, fields: [Field], description: String? = nil, version: Int = 1) {
        self.name = name
        self.fields = fields
        self.description = description
        self.version = version
    }
}
