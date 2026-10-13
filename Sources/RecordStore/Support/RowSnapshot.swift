//
//  RowSnapshot.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A stored row, exactly, as text — what the undo journal keeps. Each value
//  is tagged with its SQLite storage class so an integer comes back an
//  integer and a real a real; JSON numbers alone would blur the two.
//

import Foundation

enum RowSnapshot {

    static func text(_ row: Database.Row) -> String {
        var object: [String: JSONValue] = [:]
        for (name, value) in zip(row.columns, row.values) {
            object[name] = tagged(value)
        }
        return JSONCoding.text(.object(object))
    }

    static func values(_ text: String) throws(RecordStoreError) -> [String: Database.Value] {
        guard case .object(let object) = try JSONCoding.parse(text) else { throw .storage("journal snapshot is not an object") }
        return object.mapValues(untagged)
    }

    static func tagged(_ value: Database.Value) -> JSONValue {
        switch value {
        case .null: return .null
        case .int(let i): return .object(["i": .string(String(i))])
        case .real(let d): return .object(["r": .string("\(d)")])
        case .text(let s): return .object(["t": .string(s)])
        case .blob(let b): return .object(["b": .string(b.base64EncodedString())])
        }
    }

    static func untagged(_ value: JSONValue) -> Database.Value {
        guard case .object(let o) = value, let (tag, payload) = o.first, case .string(let s) = payload else { return .null }
        switch tag {
        case "i": return Int64(s).map(Database.Value.int) ?? .null
        case "r": return Double(s).map(Database.Value.real) ?? .null
        case "t": return .text(s)
        case "b": return Data(base64Encoded: s).map(Database.Value.blob) ?? .null
        default: return .null
        }
    }
}
