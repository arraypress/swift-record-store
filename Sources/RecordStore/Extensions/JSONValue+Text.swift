//
//  JSONValue+Text.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension JSONValue {

    /// Parses one JSON document.
    static func parse(_ text: String) throws(RecordStoreError) -> JSONValue { try JSONCoding.parse(text) }

    /// Parses NDJSON, or one JSON array, into objects with their line numbers.
    static func parseRecords(_ text: String) throws(RecordStoreError) -> [(line: Int, value: [String: JSONValue])] {
        try JSONCoding.parseRecords(text)
    }

    /// Compact, key-sorted JSON text.
    var jsonText: String { JSONCoding.text(self) }

    /// A short human rendering: money as `23.40 GBP`, arrays comma-joined.
    var displayText: String { ValueDisplay.text(self) }
}
