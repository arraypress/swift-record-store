//
//  StoreTests.swift
//  RecordStoreTests
//
//  Created by David Sherlock on 2026.
//

import Foundation
import Testing
@testable import RecordStore

/// A store in a fresh temporary file, with the expenses schema defined.
func makeStore() throws -> RecordStore {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString).sqlite").path
    let store = try RecordStore(path: path)
    store.now = { Date(timeIntervalSince1970: 1_791_900_000) }
    store.timeZone = TimeZone(secondsFromGMT: 0)!
    try store.define(Schema.parse(#"""
        {"name": "expenses", "fields": [
            "shop:text!", "total:money(GBP)!", "date:date!",
            "category:choice(groceries|fuel|eating out)", "tags:tags", "receipt_no:text",
            {"name": "paid", "type": "bool", "default": true}
        ]}
        """#))
    return store
}

func json(_ text: String) throws -> [String: JSONValue] {
    guard case .object(let o) = try JSONValue.parse(text) else { throw RecordStoreError.unreadableJSON("not an object") }
    return o
}

struct StoreTests {

    @Test func addChecksAndNormalises() throws {
        let store = try makeStore()
        let record = try store.add(json(#"{"shop": "Tesco", "total": "£23.40", "date": "13 Oct 2026", "category": "Groceries", "tags": "food, weekly, food"}"#), to: "expenses")
        #expect(record.id == 1)
        #expect(record.values["total"] == .object(["amount": .string("23.40"), "currency": .string("GBP")]))
        #expect(record.values["date"] == .string("2026-10-13"))
        #expect(record.values["category"] == .string("groceries"))
        #expect(record.values["tags"] == .array([.string("food"), .string("weekly")]))
        #expect(record.values["paid"] == .bool(true))   // the default
        #expect(record.addedAt == "2026-10-13T14:00:00Z")
    }

    @Test func validationNamesTheFieldAndTheReason() throws {
        let store = try makeStore()
        func message(_ text: String) -> String {
            do { _ = try store.add(json(text), to: "expenses"); return "" } catch { return (error as? RecordStoreError)?.message ?? "\(error)" }
        }
        #expect(message(#"{"total": "5 GBP", "date": "2026-10-13"}"#) == "shop: is required")
        #expect(message(#"{"shop": "x", "total": "5", "date": "2026-10-13", "category": "rent"}"#).hasPrefix("category: \"rent\" is not one of"))
        #expect(message(#"{"shop": "x", "total": "5.555", "date": "2026-10-13"}"#).contains("GBP has 2 decimal places"))
        #expect(message(#"{"shop": "x", "total": "5", "date": "03/04/2026"}"#).contains("day-first or month-first"))
        #expect(message(#"{"shop": "x", "total": "5", "date": "2026-10-13", "shoop": 1}"#) == "expenses has no field \"shoop\"")
        #expect(message(#"{"shop": "x", "total": "5", "date": "2026-10-13", "paid": "maybe"}"#) == "paid: expected true or false")
        #expect(try store.count(in: "expenses") == 0)
    }

    @Test func duplicatesBySourceAndByUniqueKey() throws {
        let store = try makeStore()
        let provenance = Provenance(source: "/tmp/r.pdf", sourceSHA256: "abc", tool: "extract")
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses", provenance: provenance)
        #expect(throws: RecordStoreError.duplicate("this source was already added as #1 — pass allow-duplicate to add it again")) {
            try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses", provenance: provenance)
        }
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses", provenance: provenance, allowDuplicate: true)
        #expect(try store.count(in: "expenses") == 2)
        #expect(try store.get(1, from: "expenses").provenance == provenance)

        try store.migrate("expenses", .addField(Field(name: "ref", type: .text, unique: true)))
        try store.add(json(#"{"shop": "B", "total": "1 GBP", "date": "2026-10-01", "ref": "R1"}"#), to: "expenses")
        #expect(throws: RecordStoreError.self) {
            try store.add(json(#"{"shop": "C", "total": "2 GBP", "date": "2026-10-02", "ref": "R1"}"#), to: "expenses")
        }
    }

    @Test func batchesAreAllOrNothing() throws {
        let store = try makeStore()
        let batch = try JSONValue.parseRecords("""
            {"shop": "A", "total": "1 GBP", "date": "2026-10-01"}
            {"shop": "B", "total": "lots", "date": "2026-10-02"}
            {"shop": "C", "total": "3 GBP"}
            """)
        #expect(throws: RecordStoreError.invalidRecords(["record 2: total: \"lots\" is not an amount", "record 3: date: is required"])) {
            try store.addAll(batch.map { ($0.line, $0.value) }, to: "expenses")
        }
        #expect(try store.count(in: "expenses") == 0)
    }

    @Test func updateGetDelete() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses")
        let updated = try store.update(1, in: "expenses", with: json(#"{"total": "2.50", "category": "fuel"}"#))
        #expect(updated.values["total"] == .object(["amount": .string("2.50"), "currency": .string("GBP")]))
        #expect(updated.updatedAt != nil)
        #expect(throws: RecordStoreError.invalidValue(field: "shop", reason: "is required")) {
            try store.update(1, in: "expenses", with: ["shop": .null])
        }
        try store.delete(1, from: "expenses")
        #expect(throws: RecordStoreError.recordNotFound(collection: "expenses", id: 1)) { try store.get(1, from: "expenses") }
        #expect(throws: RecordStoreError.unknownCollection("nope")) { try store.get(1, from: "nope") }
    }

    @Test func defineRefusesARedefinition() throws {
        let store = try makeStore()
        #expect(throws: RecordStoreError.self) { try store.define(Schema(name: "expenses", fields: [Field(name: "a", type: .text)])) }
        #expect(try store.schemas().map(\.name) == ["expenses"])
    }
}
