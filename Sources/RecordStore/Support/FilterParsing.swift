//
//  FilterParsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Reads the `field op value` filters the command line uses:
/// `total > 20 GBP`, `category = groceries`, `tags ~ work`,
/// `shop in Tesco, Aldi`, `notes = null`.
enum FilterParsing {

    static func parse(_ text: String) throws(RecordStoreError) -> Filter {
        let pattern = /^\s*([a-z_][a-z0-9_]*)\s*(!=|<=|>=|==|=|<|>|~|\s+[iI][nN]\s+)\s*(.*?)\s*$/
        guard let m = text.wholeMatch(of: pattern) else {
            throw .invalidQuery("\"\(text)\" is not a filter — write field op value, e.g. \"total > 20 GBP\" (ops: = != < <= > >= ~ in)")
        }
        let opText = String(m.2).trimmingCharacters(in: .whitespaces).lowercased()
        let op: FilterOperator = opText == "==" ? .equal : (FilterOperator(rawValue: opText) ?? .equal)
        var value = String(m.3)
        if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return Filter(field: String(m.1), op: op, value: value)
    }
}
