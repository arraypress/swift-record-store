//
//  SwiftEmitting.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A schema as Swift source: a Decodable struct an app can read the same
//  SQLite file into with `store.fetch(Type.self)`. Optional unless the field
//  is required; snake_case fields keep their stored names through CodingKeys;
//  a choice becomes a nested String enum.
//

import Foundation

enum SwiftEmitting {

    static func source(_ schema: Schema, typeName: String?, targets: [String: Schema]) -> String {
        let name = typeName ?? self.typeName(for: schema.name)
        var lines: [String] = []
        lines.append("import Foundation")
        lines.append("import RecordStore")
        lines.append("")
        if let description = schema.description, !description.isEmpty {
            lines.append("/// \(description)")
        } else {
            lines.append("/// A record of `\(schema.name)`, as RecordStore reads it.")
        }
        lines.append("struct \(name): StoredRecord, Sendable, Equatable {")
        lines.append("")
        lines.append("    static let collection = \"\(schema.name)\"")
        if let key = schema.key { lines.append("    static let keyField = \"\(key)\"") }
        lines.append("")
        lines.append("    var id: Int64")
        var enums: [String] = []
        for field in schema.fields {
            var type = swiftType(field, targets: targets)
            if field.type == .choice {
                let enumName = self.typeName(for: field.name, singular: false)
                type = enumName
                enums.append(choiceEnum(enumName, field.choices ?? []))
            }
            if let description = field.description, !description.isEmpty { lines.append("    /// \(description)") }
            else if let target = field.target { lines.append("    /// \(field.type == .ref ? "Links to" : "Links to records of") `\(target)`, by \(targets[target]?.key ?? "id").") }
            lines.append("    var \(property(field.name)): \(type)\(field.required ? "" : "?")")
        }
        let renamed = schema.fields.filter { property($0.name) != $0.name }
        if !renamed.isEmpty {
            lines.append("")
            lines.append("    enum CodingKeys: String, CodingKey {")
            lines.append("        case id")
            for field in schema.fields {
                let p = property(field.name)
                lines.append(p == field.name ? "        case \(p)" : "        case \(p) = \"\(field.name)\"")
            }
            lines.append("    }")
        }
        for e in enums {
            lines.append("")
            lines.append(e)
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    static func swiftType(_ field: Field, targets: [String: Schema]) -> String {
        switch field.type {
        case .text, .date: return "String"
        case .number: return "Double"
        case .integer: return "Int"
        case .money: return "Money"
        case .datetime: return "Date"
        case .bool: return "Bool"
        case .choice: return "String"
        case .tags: return "[String]"
        case .range: return "[Double]"
        case .ref: return field.target.flatMap { targets[$0]?.key } != nil ? "String" : "Int64"
        case .refs: return field.target.flatMap { targets[$0]?.key } != nil ? "[String]" : "[Int64]"
        }
    }

    /// `daily_entries` → `DailyEntry`; `expenses` → `Expense`.
    static func typeName(for name: String, singular: Bool = true) -> String {
        var base = name
        if singular {
            if base.hasSuffix("ies") { base = String(base.dropLast(3)) + "y" }
            else if base.hasSuffix("s"), !base.hasSuffix("ss") { base = String(base.dropLast()) }
        }
        let words = base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let joined = words.joined()
        return joined.first?.isNumber == true ? "T" + joined : joined
    }

    /// `onset_hours` → `onsetHours`, escaped if it is a keyword.
    static func property(_ name: String) -> String {
        let parts = name.split(separator: "_")
        guard let first = parts.first else { return name }
        let camel = String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return keywords.contains(camel) ? "`\(camel)`" : camel
    }

    static func choiceEnum(_ name: String, _ choices: [String]) -> String {
        var lines = ["    enum \(name): String, Codable, CaseIterable, Sendable {"]
        var used = Set<String>()
        for choice in choices {
            let words = choice.lowercased().split { !$0.isLetter && !$0.isNumber }
            var label = words.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
            if label.isEmpty || label.first!.isNumber { label = "value" + label.prefix(1).uppercased() + label.dropFirst() }
            while used.contains(label) { label += "_" }
            used.insert(label)
            if keywords.contains(label) { label = "`\(label)`" }
            lines.append(label == choice ? "        case \(label)" : "        case \(label) = \"\(choice.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal",
        "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
        "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
        "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw",
        "throws", "true", "try", "Type", "Protocol", "any", "some",
    ]
}
