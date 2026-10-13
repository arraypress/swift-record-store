//
//  Schema+Parsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension Schema {

    /// Reads a schema from JSON. Each field is an object
    /// (`{"name": "total", "type": "money", "required": true}`) or the
    /// shorthand string `"total:money(GBP)!"`.
    static func parse(_ text: String, name: String? = nil) throws(RecordStoreError) -> Schema {
        try SchemaParsing.parse(text, name: name)
    }

    /// The schema's fields, validated, from shorthand specs such as
    /// `["shop:text!", "total:money(GBP)!", "date:date!"]`.
    static func fields(fromSpecs specs: [String]) throws(RecordStoreError) -> [Field] {
        try specs.map { (spec: String) throws(RecordStoreError) -> Field in try SchemaRules.field(fromSpec: spec) }
    }
}

public extension Field {

    /// A field from its shorthand: `name:type`, `name:type!`,
    /// `name:money(GBP)`, `name:choice(a|b)`, `name:type=default`.
    static func parse(spec: String) throws(RecordStoreError) -> Field { try SchemaRules.field(fromSpec: spec) }

    /// The SQLite columns this field is stored in.
    var columnNames: [String] { SchemaRules.columns(of: self) }
}

public extension Filter {

    /// A filter from `field op value` text.
    static func parse(_ text: String) throws(RecordStoreError) -> Filter { try FilterParsing.parse(text) }
}

public extension Money {

    /// Reads money text such as "23.40 GBP" or "£23.40".
    static func parse(_ text: String, defaultCurrency: String? = nil) throws(RecordStoreError) -> Money {
        do throws(MoneyFailure) {
            return try MoneyParsing.parse(text, defaultCurrency: defaultCurrency)
        } catch {
            throw .invalidValue(field: "", reason: error.reason)
        }
    }

    /// The amount as decimal text: "23.40".
    var amountText: String { MoneyParsing.amountText(self) }
}
