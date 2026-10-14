//
//  KeyedRecords.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Catalogue files keyed by name — `{"triggers": {"dairy": {…}, "gluten":
//  {…}}, "version": "1.1"}` — as records of a keyed collection: each member
//  becomes a record whose key is the member's name. Other members beside
//  the map (a version, a date) are left alone. Records come out in key
//  order, since a JSON object's order is not something to rely on.
//

import Foundation

enum KeyedRecords {

    /// The records in `object`, or nil when it reads as one plain record (it
    /// names a field of the schema). `under` picks the member holding the
    /// map; otherwise it is the object itself when every value is an
    /// object, or else its only member that is a map of objects.
    static func records(_ object: [String: JSONValue], schema: Schema,
                        under: String?) throws(RecordStoreError) -> [(label: String, value: [String: JSONValue])]? {
        guard let key = schema.key else {
            if under != nil { throw .invalidQuery("\(schema.name) has no key, so a keyed file has nothing to name its records by") }
            return nil
        }
        let map: [String: JSONValue]
        if let under {
            guard case .object(let chosen)? = object[under] else {
                throw .unreadableJSON("there is no object \"\(under)\" in the file")
            }
            map = chosen
        } else {
            if object.keys.contains(where: { schema.field($0) != nil }) { return nil }
            // Two readings: the object is the map ({"dairy": {…}}), or one of
            // its members is ({"triggers": {"dairy": {…}}, "version": "1"}).
            // The one whose records name only the schema's fields wins.
            let fields = Set(schema.fields.map(\.name))
            func records(of value: [String: JSONValue]) -> [[String: JSONValue]]? {
                guard !value.isEmpty else { return nil }
                var out: [[String: JSONValue]] = []
                for item in value.values {
                    guard case .object(let record) = item else { return nil }
                    out.append(record)
                }
                return out
            }
            func fits(_ records: [[String: JSONValue]]) -> Bool { records.allSatisfy { Set($0.keys).isSubset(of: fields) } }
            let direct = records(of: object)
            let wrappers = object.compactMap { name, value -> (String, [String: JSONValue], [[String: JSONValue]])? in
                guard case .object(let inner) = value, let found = records(of: inner) else { return nil }
                return (name, inner, found)
            }
            let fittingWrappers = wrappers.filter { fits($0.2) }
            if let direct, fits(direct), fittingWrappers.isEmpty {
                map = object
            } else if fittingWrappers.count == 1, direct.map(fits) != true {
                map = fittingWrappers[0].1
            } else if fittingWrappers.count > 1 || (fittingWrappers.count == 1 && direct.map(fits) == true) {
                throw .unreadableJSON("the file can be read more than one way (\(wrappers.map(\.0).sorted().joined(separator: ", "))) — name the member with under")
            } else if wrappers.count == 1 {
                map = wrappers[0].1         // the unknown fields will be named
            } else if direct != nil {
                map = object
            } else {
                return nil
            }
        }
        var out: [(String, [String: JSONValue])] = []
        for name in map.keys.sorted() {
            guard case .object(var record) = map[name]! else { continue }
            if let given = record[key], given != .string(name) {
                throw .invalidRecords(["record \(name): \(key) is \(given.jsonText) but the record is filed under \"\(name)\""])
            }
            record[key] = .string(name)
            out.append((name, record))
        }
        return out
    }

    private static func isObject(_ value: JSONValue) -> Bool {
        if case .object = value { return true }
        return false
    }
}
