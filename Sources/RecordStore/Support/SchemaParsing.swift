//
//  SchemaParsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Reads schema JSON, accepting shorthand strings for fields.
enum SchemaParsing {

    static func parse(_ text: String, name: String?) throws(RecordStoreError) -> Schema {
        guard case .object(var object) = try JSONCoding.parse(text) else {
            throw .invalidSchema("a schema is a JSON object with \"fields\"")
        }
        if let name { object["name"] = .string(name) }
        guard case .string(let schemaName)? = object["name"] else { throw .invalidSchema("the schema needs a \"name\"") }
        guard case .array(let rawFields)? = object["fields"] else { throw .invalidSchema("the schema needs a \"fields\" array") }

        let known: Set<String> = ["name", "fields", "description", "version"]
        if let extra = object.keys.first(where: { !known.contains($0) }) {
            throw .invalidSchema("unknown key \"\(extra)\" — a schema has name, description and fields")
        }
        var fields: [Field] = []
        for (index, raw) in rawFields.enumerated() {
            switch raw {
            case .string(let spec):
                fields.append(try SchemaRules.field(fromSpec: spec))
            case .object(let fieldObject):
                let allowed: Set<String> = ["name", "type", "required", "default", "unique", "description", "choices", "currency"]
                if let extra = fieldObject.keys.first(where: { !allowed.contains($0) }) {
                    throw .invalidSchema("field \(index + 1) has an unknown key \"\(extra)\" — fields take \(allowed.sorted().joined(separator: ", "))")
                }
                guard case .string(let typeName)? = fieldObject["type"], let type = FieldType(rawValue: typeName.lowercased()) else {
                    throw .invalidSchema("field \(index + 1) needs a \"type\": one of \(FieldType.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                var field = try JSONCoding.decode(Field.self, from: JSONCoding.text(.object(fieldObject.merging(
                    ["type": .string(type.rawValue), "required": fieldObject["required"] ?? .bool(false), "unique": fieldObject["unique"] ?? .bool(false)],
                    uniquingKeysWith: { $1 }))))
                field.type = type
                fields.append(field)
            default:
                throw .invalidSchema("field \(index + 1) is neither an object nor a \"name:type\" string")
            }
        }
        var description: String?
        if case .string(let d)? = object["description"] { description = d }
        return try SchemaRules.validated(Schema(name: schemaName, fields: fields, description: description))
    }
}
