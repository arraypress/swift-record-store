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

    /// The field whose text names a record — `bloating`, `dairy` — so that
    /// get, update, delete and links can use it instead of the id. Required,
    /// unique (without regard to case) and never a bare number. `nil` (every
    /// database written before 0.2) means records are named by id alone.
    public var key: String?

    /// Report specs saved with the collection, by name.
    public var reports: [ReportSpec]?

    public init(name: String, fields: [Field], description: String? = nil, version: Int = 1,
                key: String? = nil, reports: [ReportSpec]? = nil) {
        self.name = name
        self.fields = fields
        self.description = description
        self.version = version
        self.key = key
        self.reports = reports
    }
}
