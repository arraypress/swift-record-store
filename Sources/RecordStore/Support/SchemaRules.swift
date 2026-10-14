//
//  SchemaRules.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  What a schema may say, and how its fields become columns. A collection's
//  name is its table's name, so `store sql "SELECT … FROM expenses"` reads
//  naturally; the store's own tables are `_store_*` and no collection may
//  start with an underscore.
//

import Foundation

enum SchemaRules {

    /// Columns every collection table carries besides its fields.
    static let metaColumns = ["_source", "_source_sha256", "_tool", "_added_at", "_updated_at"]

    /// The suffix of a money field's currency column.
    static let currencySuffix = "__currency"

    /// The suffix of a range field's upper-bound column.
    static let rangeSuffix = "__max"

    /// Lowercase letters, digits and underscores, starting with a letter; no
    /// double underscore (that is how a money field's currency column is named).
    static func isIdentifier(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z][a-z0-9_]{0,62}/) != nil && !name.contains("__") && !name.hasSuffix("_")
    }

    /// Validates a whole schema and returns it normalised (choices trimmed,
    /// currencies uppercased, defaults checked against their types).
    static func validated(_ schema: Schema) throws(RecordStoreError) -> Schema {
        guard isIdentifier(schema.name), !schema.name.hasPrefix("sqlite") else {
            throw .invalidSchema("\"\(schema.name)\" is not a usable name: lowercase letters, digits and single underscores, starting with a letter")
        }
        guard !schema.fields.isEmpty else { throw .invalidSchema("a schema needs at least one field") }
        var seen = Set<String>()
        var out = schema
        out.fields = []
        for field in schema.fields {
            let checked = try validated(field)
            guard seen.insert(checked.name).inserted else { throw .invalidSchema("field \"\(checked.name)\" appears twice") }
            out.fields.append(checked)
        }
        if let key = schema.key {
            guard let index = out.fields.firstIndex(where: { $0.name == key }) else {
                throw .invalidSchema("the key \"\(key)\" is not one of the fields")
            }
            out.fields[index] = try keyed(out.fields[index])
        }
        var names = Set<String>()
        for report in schema.reports ?? [] {
            guard let name = report.name, isIdentifier(name) else {
                throw .invalidSchema("a saved report needs a name: lowercase letters, digits and single underscores")
            }
            guard names.insert(name).inserted else { throw .invalidSchema("report \"\(name)\" appears twice") }
        }
        return out
    }

    /// A field made fit to be the key: text, required, unique.
    static func keyed(_ field: Field) throws(RecordStoreError) -> Field {
        guard field.type == .text else {
            throw .invalidSchema("the key \"\(field.name)\" must be a text field (it is \(field.type.rawValue))")
        }
        guard field.default == nil || field.default == .null else {
            throw .invalidSchema("the key \"\(field.name)\" cannot have a default — every record needs its own")
        }
        var field = field
        field.required = true
        field.unique = true
        return field
    }

    /// Why `text` cannot name a record, or nil when it can. A key that is a
    /// bare number would read as an id; one starting with `#` likewise.
    static func keyProblem(_ text: String) -> String? {
        if text.isEmpty { return "a key cannot be empty" }
        if text.hasPrefix("#") { return "a key cannot start with # (that names an id)" }
        if text.allSatisfy(\.isNumber) { return "a key cannot be a bare number — it would read as an id" }
        if text.contains(",") { return "a key cannot contain a comma — lists of keys are comma-separated" }
        return nil
    }

    /// Validates one field.
    static func validated(_ field: Field) throws(RecordStoreError) -> Field {
        var field = field
        guard isIdentifier(field.name), field.name != "id" else {
            throw .invalidSchema("\"\(field.name)\" is not a usable field name: lowercase letters, digits and single underscores, starting with a letter; \"id\" is taken")
        }
        if field.type == .choice {
            let choices = (field.choices ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !choices.isEmpty else { throw .invalidSchema("choice field \"\(field.name)\" needs \"choices\"") }
            guard Set(choices.map { $0.lowercased() }).count == choices.count else {
                throw .invalidSchema("choice field \"\(field.name)\" lists a choice twice")
            }
            field.choices = choices
        } else if field.choices != nil {
            throw .invalidSchema("\"choices\" only applies to choice fields (\"\(field.name)\" is \(field.type.rawValue))")
        }
        if field.isLink {
            guard let target = field.target?.trimmingCharacters(in: .whitespaces), isIdentifier(target) else {
                throw .invalidSchema("link field \"\(field.name)\" needs the collection it links to: \(field.type.rawValue)(collection)")
            }
            field.target = target
            if field.unique { throw .invalidSchema("link field \"\(field.name)\" cannot be unique") }
        } else if field.target != nil {
            throw .invalidSchema("\"target\" only applies to ref and refs fields (\"\(field.name)\" is \(field.type.rawValue))")
        }
        if field.unique, [.tags, .range].contains(field.type) {
            throw .invalidSchema("a \(field.type.rawValue) field cannot be unique")
        }
        if let currency = field.currency {
            guard field.type == .money else { throw .invalidSchema("\"currency\" only applies to money fields") }
            guard Currencies.isKnown(currency.uppercased()) else { throw .invalidSchema("\"\(currency)\" is not an ISO 4217 currency") }
            field.currency = currency.uppercased()
        }
        if let value = field.default, value != .null, !field.isLink {
            do {
                _ = try ValueCoercion.columns(for: value, field: field, now: Date(), timeZone: .current)
            } catch {
                throw .invalidSchema("the default for \"\(field.name)\" does not fit: \(error.reasonText)")
            }
        }
        return field
    }

    /// The column names a field occupies.
    static func columns(of field: Field) -> [String] {
        switch field.type {
        case .money: return [field.name, field.name + currencySuffix]
        case .range: return [field.name, field.name + rangeSuffix]
        default: return [field.name]
        }
    }

    /// The SQL declaration of a field's columns.
    static func declarations(of field: Field) -> [String] {
        let type: String
        switch field.type {
        case .number: type = "REAL"
        case .integer, .bool: type = "INTEGER"
        case .money: return ["\(SQLText.quoted(field.name)) INTEGER", "\(SQLText.quoted(field.name + currencySuffix)) TEXT"]
        case .range: return ["\(SQLText.quoted(field.name)) REAL", "\(SQLText.quoted(field.name + rangeSuffix)) REAL"]
        // No affinity: a key stays text and an id stays an integer.
        case .ref: return [SQLText.quoted(field.name)]
        case .text, .date, .datetime, .choice, .tags, .refs: type = "TEXT"
        }
        return ["\(SQLText.quoted(field.name)) \(type)"]
    }

    /// Reads the field shorthand used on the command line:
    /// `name:type`, `name:type!` (required), `name:money(GBP)`,
    /// `name:choice(a|b|c)`, `name:ref(collection)`, `name:type=default`.
    static func field(fromSpec spec: String) throws(RecordStoreError) -> Field {
        guard let m = spec.trimmingCharacters(in: .whitespaces).wholeMatch(of: /([a-z][a-z0-9_]*):([a-z]+)(?:\(([^)]*)\))?(!)?(?:=(.*))?/) else {
            throw .invalidSchema("\"\(spec)\" is not a field spec — write name:type, e.g. total:money(GBP)! or category:choice(food|fuel)")
        }
        guard let type = FieldType(rawValue: String(m.2)) else {
            throw .invalidSchema("unknown type \"\(m.2)\" — one of \(FieldType.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var field = Field(name: String(m.1), type: type, required: m.4 != nil)
        if let argument = m.3.map(String.init) {
            switch type {
            // `a|b|c`; `a,b,c` is read the same way when there is no `|` —
            // it used to become ONE choice that no value ever matched.
            case .choice:
                let separator: Character = argument.contains("|") ? "|" : ","
                field.choices = argument.split(separator: separator)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .money: field.currency = argument
            case .ref, .refs: field.target = argument
            default: throw .invalidSchema("\(type.rawValue) takes no (…) argument")
            }
        }
        if let raw = m.5.map(String.init) {
            field.default = (try? JSONCoding.parse(raw)) ?? .string(raw)
        }
        return try validated(field)
    }
}
