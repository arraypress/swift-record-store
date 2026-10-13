//
//  JSONCoding.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  JSON text ⇄ JSONValue. Parsing goes through JSONSerialization, then each
//  NSNumber is read back through its string form into a Decimal — so the
//  digits a person typed are the digits the money parser sees.
//

import CoreFoundation
import Foundation

enum JSONCoding {

    /// Parses one JSON document.
    static func parse(_ text: String) throws(RecordStoreError) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .unreadableJSON("empty input") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            throw .unreadableJSON(Self.reason(error))
        }
        return value(from: object)
    }

    /// Parses newline-delimited JSON, or a single JSON array, into records.
    ///
    /// - Returns: the objects, with the 1-based line (or element) each came from.
    static func parseRecords(_ text: String) throws(RecordStoreError) -> [(line: Int, value: [String: JSONValue])] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard case .array(let items) = try parse(trimmed) else { throw .unreadableJSON("expected an array") }
            var out: [(Int, [String: JSONValue])] = []
            for (index, item) in items.enumerated() {
                guard case .object(let object) = item else { throw .unreadableJSON("element \(index + 1) is not an object") }
                out.append((index + 1, object))
            }
            return out
        }
        var out: [(Int, [String: JSONValue])] = []
        for (index, line) in trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let parsed: JSONValue
            do { parsed = try parse(text) } catch { throw .unreadableJSON("line \(index + 1): \(Self.message(error))") }
            guard case .object(let object) = parsed else { throw .unreadableJSON("line \(index + 1) is not an object") }
            out.append((index + 1, object))
        }
        return out
    }

    /// Converts a JSONSerialization object tree.
    static func value(from object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) ?? number.decimalValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(value(from:)))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(value(from:)))
        default:
            return .null
        }
    }

    /// The JSONSerialization object tree for a value.
    static func object(from value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let d): return NSDecimalNumber(decimal: d)
        case .string(let s): return s
        case .array(let a): return a.map(object(from:))
        case .object(let o): return o.mapValues(object(from:))
        }
    }

    /// Compact, key-sorted JSON text.
    static func text(_ value: JSONValue) -> String {
        let object = object(from: value)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text of a Codable value (schemas), compact and key-sorted.
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a Codable value (schemas) from JSON text.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws(RecordStoreError) -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw .unreadableJSON(Self.reason(error))
        }
    }

    private static func reason(_ error: any Error) -> String {
        if case DecodingError.keyNotFound(let key, let context) = error {
            return "missing \"\(key.stringValue)\"" + Self.path(context.codingPath)
        }
        if case DecodingError.typeMismatch(_, let context) = error {
            return context.debugDescription + Self.path(context.codingPath)
        }
        if case DecodingError.dataCorrupted(let context) = error {
            return context.debugDescription + Self.path(context.codingPath)
        }
        let ns = error as NSError
        return (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        let parts = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return parts.isEmpty ? "" : " (at \(parts))"
    }

    private static func message(_ error: RecordStoreError) -> String {
        if case .unreadableJSON(let reason) = error { return reason }
        return "\(error)"
    }
}
