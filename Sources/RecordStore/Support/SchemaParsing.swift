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

        let known: Set<String> = ["name", "fields", "description", "version", "key", "reports"]
        if let extra = object.keys.first(where: { !known.contains($0) }) {
            throw .invalidSchema("unknown key \"\(extra)\" — a schema has name, description, key, fields and reports")
        }
        var fields: [Field] = []
        for (index, raw) in rawFields.enumerated() {
            switch raw {
            case .string(let spec):
                fields.append(try SchemaRules.field(fromSpec: spec))
            case .object(let fieldObject):
                var fieldObject = fieldObject
                let allowed: Set<String> = ["name", "type", "required", "default", "unique", "description", "choices", "currency", "target"]
                if let extra = fieldObject.keys.first(where: { !allowed.contains($0) }) {
                    throw .invalidSchema("field \(index + 1) has an unknown key \"\(extra)\" — fields take \(allowed.sorted().joined(separator: ", "))")
                }
                // "ref(triggers)" in an object reads as the shorthand does.
                if case .string(let written)? = fieldObject["type"],
                   let m = written.trimmingCharacters(in: .whitespaces).wholeMatch(of: /([a-zA-Z]+)\((.*)\)/) {
                    fieldObject["type"] = .string(String(m.1))
                    let argument = String(m.2).trimmingCharacters(in: .whitespaces)
                    switch FieldType(rawValue: String(m.1).lowercased()) {
                    case .ref?, .refs?: if fieldObject["target"] == nil { fieldObject["target"] = .string(argument) }
                    case .money?: if fieldObject["currency"] == nil { fieldObject["currency"] = .string(argument) }
                    case .choice?:
                        if fieldObject["choices"] == nil {
                            let separator: Character = argument.contains("|") ? "|" : ","
                            fieldObject["choices"] = .array(argument.split(separator: separator).map { .string($0.trimmingCharacters(in: .whitespaces)) })
                        }
                    default: throw .invalidSchema("field \(index + 1): \(m.1) takes no (…) argument")
                    }
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
        var key: String?
        switch object["key"] {
        case .string(let k)?: key = k
        case nil, .null?: key = nil
        default: throw .invalidSchema("\"key\" names a text field")
        }
        var reports: [ReportSpec]?
        if let raw = object["reports"], raw != .null {
            reports = try JSONCoding.decode([ReportSpec].self, from: JSONCoding.text(raw))
        }
        // A key named but not among the fields becomes the first field.
        if let key, !fields.contains(where: { $0.name == key }) {
            fields.insert(Field(name: key, type: .text, required: true, unique: true), at: 0)
        }
        return try SchemaRules.validated(Schema(name: schemaName, fields: fields, description: description, key: key, reports: reports))
    }
}
