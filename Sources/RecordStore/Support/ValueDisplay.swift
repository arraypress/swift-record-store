//
//  ValueDisplay.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Short human renderings of values, for tables.
enum ValueDisplay {

    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "yes" : "no"
        case .number(let d): return NSDecimalNumber(decimal: d).stringValue
        case .string(let s): return s
        case .array(let items): return items.map(text).joined(separator: ", ")
        case .object(let o):
            if case .string(let amount)? = o["amount"], case .string(let currency)? = o["currency"] {
                return "\(amount) \(currency)"
            }
            return JSONCoding.text(value)
        }
    }
}
