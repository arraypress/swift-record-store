//
//  JournalTests.swift
//  RecordStoreTests
//
//  Created by David Sherlock on 2026.
//

import Foundation
import Testing
@testable import RecordStore

struct JournalTests {

    @Test func everyWriteUndoesExactly() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01", "tags": ["x"]}"#), to: "expenses")
        let original = try store.get(1, from: "expenses")

        try store.update(1, in: "expenses", with: json(#"{"shop": "B", "total": "9.99 EUR"}"#))
        try store.undo()
        #expect(try store.get(1, from: "expenses") == original)

        try store.delete(1, from: "expenses")
        try store.undo()
        #expect(try store.get(1, from: "expenses") == original)   // same id, same values

        try store.undo()   // the insert
        #expect(try store.count(in: "expenses") == 0)
        try store.undo()   // the definition, now the table is empty
        #expect(try store.schemas().isEmpty)
        #expect(throws: RecordStoreError.cannotUndo("nothing to undo")) { try store.undo() }
    }

    @Test func undoneEntriesCannotBeAppliedTwice() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses")
        let entry = try store.undo()
        #expect(entry.undone && entry.action == .insert)
        #expect(throws: RecordStoreError.cannotUndo("entry #\(entry.id) was already undone")) { try store.undo(entry: entry.id) }
    }

    @Test func aLaterChangeBlocksUndoingAnEarlierOne() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses")
        try store.update(1, in: "expenses", with: ["shop": .string("B")])
        let insert = try store.history().first { $0.action == .insert }!
        #expect(throws: RecordStoreError.self) { try store.undo(entry: insert.id) }
        #expect(try store.get(1, from: "expenses").values["shop"] == .string("B"))
    }

    @Test func historyIsNewestFirst() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses")
        let history = try store.history()
        #expect(history.map(\.action) == [.insert, .define])
        #expect(history.first?.summary == "added #1")
    }
}

struct MigrationTests {

    @Test func addRenameDropAndUndoEach() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses")

        let added = try store.migrate("expenses", .addField(Field.parse(spec: "vat:money(GBP)=0.20")))
        #expect(added.version == 2)
        #expect(try store.get(1, from: "expenses").values["vat"] == money("0.20", "GBP"))

        try store.migrate("expenses", .renameField(from: "shop", to: "merchant"))
        #expect(try store.get(1, from: "expenses").values["merchant"] == .string("A"))
        let found = try store.query("expenses", Query(filters: [Filter.parse("merchant = A")]))
        #expect(found.rows.count == 1)

        try store.migrate("expenses", .dropField("total"))
        #expect(try store.get(1, from: "expenses").values["total"] == nil)

        try store.undo()   // drop → the values come back
        #expect(try store.get(1, from: "expenses").values["total"] == money("1.00", "GBP"))
        try store.undo()   // rename
        #expect(try store.get(1, from: "expenses").values["shop"] == .string("A"))
        try store.undo()   // add
        let schema = try store.schema(named: "expenses")
        #expect(!schema.fields.contains { $0.name == "vat" })
        #expect(schema.version == 1)
    }

    @Test func requiredFieldsNeedADefaultOnceThereAreRecords() throws {
        let store = try makeStore()
        try store.add(json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#), to: "expenses")
        #expect(throws: RecordStoreError.invalidSchema("\"vendor\" is required but expenses already has records — give it a default")) {
            try store.migrate("expenses", .addField(Field.parse(spec: "vendor:text!")))
        }
        try store.migrate("expenses", .addField(Field.parse(spec: "vendor:text!=unknown")))
        #expect(try store.get(1, from: "expenses").values["vendor"] == .string("unknown"))
    }
}

struct SQLTests {

    @Test func readOnlyRefusesWritesAtTheEngine() throws {
        let store = try seeded()
        let result = try store.readOnlySQL("SELECT shop, SUM(total) AS pence FROM expenses WHERE total__currency = 'GBP' GROUP BY shop ORDER BY shop")
        #expect(result.columns == ["shop", "pence"])
        #expect(result.rows.first == ["shop": .string("Aldi"), "pence": .number(725)])

        for statement in ["DELETE FROM expenses", "DROP TABLE expenses", "UPDATE expenses SET shop = 'x'",
                          "INSERT INTO expenses (shop) VALUES ('x')", "PRAGMA query_only = 0; DELETE FROM expenses"] {
            #expect(throws: RecordStoreError.self) { try store.readOnlySQL(statement) }
        }
        #expect(try store.count(in: "expenses") == 5)
    }
}
