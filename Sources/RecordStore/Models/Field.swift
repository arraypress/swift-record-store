//
//  Field.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One field of a schema.
public struct Field: Codable, Sendable, Equatable {

    /// Lowercase letters, digits and underscores, starting with a letter.
    public var name: String

    /// What it holds.
    public var type: FieldType

    /// Whether every record must give it (after any default).
    public var required: Bool

    /// The value used when a record leaves it out.
    public var `default`: JSONValue?

    /// Whether two records may not share a value.
    public var unique: Bool

    /// What it means, for whoever reads the schema next.
    public var description: String?

    /// For ``FieldType/choice``: the allowed values.
    public var choices: [String]?

    /// For ``FieldType/money``: the currency a bare number is in.
    public var currency: String?

    /// For ``FieldType/ref`` and ``FieldType/refs``: the collection linked to.
    public var target: String?

    public init(
        name: String,
        type: FieldType,
        required: Bool = false,
        default: JSONValue? = nil,
        unique: Bool = false,
        description: String? = nil,
        choices: [String]? = nil,
        currency: String? = nil,
        target: String? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.default = `default`
        self.unique = unique
        self.description = description
        self.choices = choices
        self.currency = currency
        self.target = target
    }
}
