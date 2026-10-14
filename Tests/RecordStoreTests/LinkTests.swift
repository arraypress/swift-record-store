//
//  LinkTests.swift
//  RecordStoreTests
//
//  Created by David Sherlock on 2026.
//
//  Keys and links over a small made-up catalogue: body areas, ingredients,
//  symptoms that list the ingredients they are said to follow, a symptom
//  log and meals.
//

import Foundation
import Testing
@testable import RecordStore

/// A store with the catalogue defined and filled.
func catalogue() throws -> RecordStore {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString).sqlite").path
    let store = try RecordStore(path: path)
    store.now = { Date(timeIntervalSince1970: 1_791_900_000) }   // 2026-10-13T14:00:00Z
    store.timeZone = TimeZone(secondsFromGMT: 0)!
    try store.define(Schema.parse(#"{"name": "areas", "key": "slug", "fields": ["label:text!", "rank:integer"]}"#))
    try store.define(Schema.parse(#"{"name": "ingredients", "key": "slug", "fields": ["label:text!", "kind:choice(grain|dairy|seasoning|nut)"]}"#))
    try store.define(Schema.parse(#"""
        {"name": "symptoms", "key": "slug", "fields": [
            "label:text!", "area:ref(areas)!", "follows:refs(ingredients)", "onset_hours:range"
        ]}
        """#))
    try store.addAll(labelled: [("head", ["slug": .string("head"), "label": .string("Head"), "rank": .number(2)]),
                                ("gut", ["slug": .string("gut"), "label": .string("Gut"), "rank": .number(1)])], to: "areas")
    try store.addAll(labelled: [
        ("oat", try json(#"{"slug": "oat", "label": "Oat", "kind": "grain"}"#)),
        ("curd", try json(#"{"slug": "curd", "label": "Curd", "kind": "dairy"}"#)),
        ("brine", try json(#"{"slug": "brine", "label": "Brine", "kind": "seasoning"}"#)),
        ("kernel", try json(#"{"slug": "kernel", "label": "Kernel", "kind": "nut"}"#)),
    ], to: "ingredients")
    try store.add(json(#"{"slug": "throb", "label": "Throb", "area": "Head", "follows": ["brine"], "onset_hours": [1, 4]}"#), to: "symptoms")
    try store.add(json(#"{"slug": "churn", "label": "Churn", "area": "gut", "follows": "curd, OAT", "onset_hours": "0.5..2"}"#), to: "symptoms")
    try store.add(json(##"{"slug": "itch", "label": "Itch", "area": "#1", "follows": ["kernel", "curd"]}"##), to: "symptoms")
    return store
}

struct KeyTests {

    @Test func keysNameRecordsWithoutRegardToCase() throws {
        let store = try catalogue()
        let schema = try store.schema(named: "areas")
        #expect(schema.key == "slug")
        #expect(schema.fields.first == Field(name: "slug", type: .text, required: true, unique: true))   // added for the key
        #expect(try store.get("HEAD", from: "areas").values["label"] == .string("Head"))
        #expect(try store.get("#2", from: "areas").values["slug"] == .string("gut"))
        #expect(try store.get("2", from: "areas").values["slug"] == .string("gut"))   // no key reads "2", so it is an id
        #expect(throws: RecordStoreError.keyNotFound(collection: "areas", key: "toe")) { try store.get("toe", from: "areas") }
    }

    @Test func aKeyMustNameOneRecordAndNotLookLikeAnId() throws {
        let store = try catalogue()
        #expect(throws: RecordStoreError.self) { try store.add(["slug": .string("Gut"), "label": .string("again")], to: "areas") }
        #expect(throws: RecordStoreError.invalidValue(field: "slug", reason: "a key cannot be a bare number — it would read as an id")) {
            try store.add(["slug": .string("42"), "label": .string("x")], to: "areas")
        }
        #expect(throws: RecordStoreError.invalidValue(field: "slug", reason: "is required")) {
            try store.add(["label": .string("x")], to: "areas")
        }
        let trimmed = try store.add(["slug": .string("  limb "), "label": .string("Limb")], to: "areas")
        #expect(trimmed.values["slug"] == .string("limb"))
    }

    @Test func keyedFilesBecomeRecordsKeyedByTheirMembers() throws {
        let store = try catalogue()
        let schema = try store.schema(named: "areas")
        let file = try json(#"{"version": "2", "updated": "2026-10-01", "areas": {"limb": {"label": "Limb"}, "skin": {"label": "Skin", "rank": 3}}}"#)
        let records = try #require(try schema.keyedRecords(in: file))
        #expect(records.map(\.label) == ["limb", "skin"])
        #expect(records[1].value == ["slug": .string("skin"), "label": .string("Skin"), "rank": .number(3)])
        // The map itself, or a member named outright.
        #expect(try schema.keyedRecords(in: json(#"{"limb": {"label": "Limb"}}"#))?.count == 1)
        #expect(try schema.keyedRecords(in: file, under: "areas")?.count == 2)
        // One member holding the map, alone: its records name the fields, so it is the map.
        #expect(try schema.keyedRecords(in: json(#"{"areas": {"limb": {"label": "Limb"}, "skin": {"label": "Skin"}}}"#))?.map(\.label) == ["limb", "skin"])
        // A plain record is not a keyed file.
        #expect(try schema.keyedRecords(in: json(#"{"slug": "limb", "label": "Limb"}"#)) == nil)
        // A record whose own key disagrees with the member it is filed under.
        #expect(throws: RecordStoreError.self) { try schema.keyedRecords(in: json(#"{"limb": {"slug": "arm", "label": "Limb"}}"#)) }
        try store.addAll(labelled: records, to: "areas")
        #expect(try store.get("skin", from: "areas").values["rank"] == .number(3))
    }

    @Test func aCatalogueMergesByKeyAndUndoesAsOneWrite() throws {
        let store = try catalogue()
        let next = try json(#"{"ingredients": {"oat": {"label": "Oat"}, "curd": {"label": "Curds", "kind": "dairy"}, "sugar": {"label": "Sugar"}}}"#)
        let records = try #require(try store.schema(named: "ingredients").keyedRecords(in: next))
        let result = try store.merge(records, into: "ingredients")
        #expect(result.added.map { $0.values["slug"] } == [.string("sugar")])
        #expect(result.updated.map { $0.values["label"] } == [.string("Curds")])
        #expect(result.unchanged == ["oat"])
        #expect(try store.get("oat", from: "ingredients").values["kind"] == .string("grain"))   // left out, so kept
        #expect(try store.count(in: "ingredients") == 5)
        try store.undo()
        #expect(try store.count(in: "ingredients") == 4)
        #expect(try store.get("curd", from: "ingredients").values["label"] == .string("Curd"))
        #expect(throws: RecordStoreError.self) { try store.merge([("x", ["slug": .string("x"), "label": .string("X"), "kind": .string("rock")])], into: "ingredients") }
        #expect(try store.count(in: "ingredients") == 4)
    }

    @Test func aCollectionMadeBeforeKeysCanTakeOne() throws {
        let store = try makeStore()
        try store.addAll([(1, json(#"{"shop": "Tesco", "total": "1 GBP", "date": "2026-10-01"}"#)),
                          (2, json(#"{"shop": "tesco", "total": "2 GBP", "date": "2026-10-02"}"#))], to: "expenses")
        #expect(throws: RecordStoreError.self) { try store.migrate("expenses", .setKey("shop")) }   // two "tesco"s
        try store.update(2, in: "expenses", with: ["shop": .string("Aldi")])
        let keyed = try store.migrate("expenses", .setKey("shop"))
        #expect(keyed.key == "shop" && keyed.field("shop")?.unique == true)
        #expect(try store.get("aldi", from: "expenses").id == 2)
        try store.migrate("expenses", .renameField(from: "shop", to: "merchant"))
        #expect(try store.schema(named: "expenses").key == "merchant")
        try store.undo()
        try store.undo()
        #expect(try store.schema(named: "expenses").key == nil)
        #expect(try store.schema(named: "expenses").field("shop")?.unique == false)
    }
}

struct LinkTests {

    @Test func linksAreResolvedAndStoredByKey() throws {
        let store = try catalogue()
        let churn = try store.get("churn", from: "symptoms")
        #expect(churn.values["area"] == .string("gut"))
        #expect(churn.values["follows"] == .array([.string("curd"), .string("oat")]))   // the target's own spelling
        #expect(churn.values["onset_hours"] == .array([.number(Decimal(string: "0.5")!), .number(2)]))
        #expect(try store.get("itch", from: "symptoms").values["area"] == .string("head"))   // "#1" became its key
    }

    @Test func aDanglingLinkIsRefusedWithTheFieldAndWhy() throws {
        let store = try catalogue()
        #expect(throws: RecordStoreError.invalidValue(field: "area", reason: "areas has no \"toe\"")) {
            try store.add(json(#"{"slug": "ache", "label": "Ache", "area": "toe"}"#), to: "symptoms")
        }
        #expect(throws: RecordStoreError.invalidValue(field: "follows", reason: "ingredients has no \"sugar\"")) {
            try store.update("throb", in: "symptoms", with: [:], adding: ["follows": ["sugar"]])
        }
        #expect(throws: RecordStoreError.invalidValue(field: "area", reason: "areas has no record #9")) {
            try store.add(json(#"{"slug": "ache", "label": "Ache", "area": 9}"#), to: "symptoms")
        }
        #expect(throws: RecordStoreError.self) {
            try store.define(Schema.parse(#"{"name": "x", "fields": ["a:ref(nowhere)"]}"#))
        }
        let added = try store.update("throb", in: "symptoms", with: [:], adding: ["follows": ["Kernel"]])
        #expect(added.values["follows"] == .array([.string("brine"), .string("kernel")]))
    }

    @Test func linksToACollectionWithoutAKeyHoldIds() throws {
        let store = try makeStore()
        try store.addAll([(1, json(#"{"shop": "A", "total": "1 GBP", "date": "2026-10-01"}"#))], to: "expenses")
        try store.define(Schema.parse(#"{"name": "claims", "fields": ["what:text!", "receipts:refs(expenses)"]}"#))
        let claim = try store.add(json(##"{"what": "trip", "receipts": [1, "#1", "1"]}"##), to: "claims")
        #expect(claim.values["receipts"] == .array([.number(1)]))
        #expect(throws: RecordStoreError.self) { try store.add(json(#"{"what": "x", "receipts": ["A"]}"#), to: "claims") }
        // Ids would change meaning under a key, so a key cannot arrive now.
        #expect(throws: RecordStoreError.self) { try store.migrate("expenses", .setKey("shop")) }
    }

    @Test func deletingWhatOthersLinkToIsRefusedUnlessForcedAndUndoIsExact() throws {
        let store = try catalogue()
        #expect(throws: RecordStoreError.self) { try store.delete("curd", from: "ingredients") }
        let churn = try store.get("churn", from: "symptoms"), itch = try store.get("itch", from: "symptoms")

        try store.delete("curd", from: "ingredients", force: true)
        #expect(try store.get("churn", from: "symptoms").values["follows"] == .array([.string("oat")]))
        #expect(try store.get("itch", from: "symptoms").values["follows"] == .array([.string("kernel")]))
        #expect(try store.check().isEmpty)

        let undone = try store.undo()   // the delete and both unlinks, as one write
        #expect(undone.summary.hasSuffix("+ 2 more in the same write"))
        #expect(try store.get("churn", from: "symptoms") == churn)
        #expect(try store.get("itch", from: "symptoms") == itch)
        #expect(try store.get("curd", from: "ingredients").values["label"] == .string("Curd"))

        // A required single link cannot be taken out, forced or not.
        #expect(throws: RecordStoreError.self) { try store.delete("gut", from: "areas", force: true) }
        #expect(try store.count(in: "areas") == 2)
    }

    @Test func aLinkedKeyCannotChangeAndUndoCannotStrandALink() throws {
        let store = try catalogue()
        #expect(throws: RecordStoreError.self) { try store.update("brine", in: "ingredients", with: ["slug": .string("salt")]) }
        try store.update("kernel", in: "ingredients", with: ["label": .string("Kernels")])   // not the key: fine

        // Adding sugar, then linking to it: undoing the add would strand the link.
        let sugar = try store.add(json(#"{"slug": "sugar", "label": "Sugar"}"#), to: "ingredients")
        try store.update("throb", in: "symptoms", with: [:], adding: ["follows": ["sugar"]])
        let insert = try #require(try store.history().first { $0.action == .insert && $0.recordID == sugar.id && $0.collection == "ingredients" })
        #expect(throws: RecordStoreError.self) { try store.undo(entry: insert.id) }
        #expect(try store.get("sugar", from: "ingredients").id == sugar.id)
        // The definition of a collection others link to cannot be undone either.
        let define = try #require(try store.history(limit: 100).first { $0.action == .define && $0.collection == "areas" })
        #expect(throws: RecordStoreError.self) { try store.undo(entry: define.id) }
    }

    @Test func checkFindsWhatSlippedPastTheWrites() throws {
        let store = try catalogue()
        #expect(try store.check().isEmpty)
        // An app writing the file directly.
        try store.db.run(#"UPDATE "symptoms" SET "follows" = '["oat","milkshake"]' WHERE "slug" = 'churn'"#)
        try store.db.run(#"UPDATE "symptoms" SET "area" = 'toe' WHERE "slug" = 'itch'"#)
        try store.db.run(#"INSERT INTO "areas" ("slug", "label") VALUES ('LIMB', 'x')"#)
        try store.db.run(#"INSERT INTO "areas" ("slug", "label") VALUES ('limb', 'y')"#)
        try store.add(json(#"{"slug": "sugar", "label": "Sugar"}"#), to: "ingredients")   // nothing follows it
        let problems = try store.check(requireLinked: ["ingredients"])
        #expect(problems.contains(IntegrityProblem(collection: "symptoms", record: "churn", field: "follows",
                                                   problem: "links to ingredients \"milkshake\", which does not exist")))
        #expect(problems.contains(IntegrityProblem(collection: "symptoms", record: "itch", field: "area",
                                                   problem: "links to areas \"toe\", which does not exist")))
        #expect(problems.contains { $0.collection == "areas" && $0.record == "limb" && $0.problem.hasPrefix("repeats the key") })
        #expect(problems.contains(IntegrityProblem(collection: "ingredients", record: "sugar", field: nil,
                                                   problem: "no record links to it (from symptoms.follows)")))
        #expect(problems.filter { $0.collection == "ingredients" }.count == 1)   // the others are all followed
        #expect(problems.count == 4)
    }

    @Test func batchesUndoAsOneWrite() throws {
        let store = try makeStore()
        let rows = try JSONValue.parseRecords("""
            {"shop": "A", "total": "1 GBP", "date": "2026-10-01"}
            {"shop": "B", "total": "2 GBP", "date": "2026-10-02"}
            {"shop": "C", "total": "3 GBP", "date": "2026-10-03"}
            """)
        try store.addAll(rows.map { ($0.line, $0.value) }, to: "expenses")
        try store.add(json(#"{"shop": "D", "total": "4 GBP", "date": "2026-10-04"}"#), to: "expenses")
        #expect(try store.history().first?.batch == nil)   // a write on its own carries none
        try store.undo()
        #expect(try store.count(in: "expenses") == 3)
        let batch = try store.undo()
        #expect(batch.summary == "added #1 + 2 more in the same write")
        #expect(try store.count(in: "expenses") == 0)
    }
}

struct LinkQueryTests {

    func ids(_ store: RecordStore, _ collection: String, _ filters: [String]) throws -> [String] {
        try store.query(collection, Query(filters: filters.map(Filter.parse))).rows.map { ValueDisplay.text($0["slug"] ?? .null) }
    }

    @Test func filtersFollowLinksAndListsAskForAnItem() throws {
        let store = try catalogue()
        #expect(try ids(store, "symptoms", ["follows ~ curd"]) == ["churn", "itch"])        // which symptoms list curd?
        #expect(try ids(store, "symptoms", ["follows ~ CURD", "area = gut"]) == ["churn"])
        #expect(try ids(store, "symptoms", ["area.label = Head"]) == ["throb", "itch"])
        #expect(try ids(store, "symptoms", ["area.rank > 1"]) == ["throb", "itch"])
        #expect(try ids(store, "symptoms", ["follows.kind = dairy"]) == ["churn", "itch"])
        #expect(try ids(store, "symptoms", ["follows.kind in nut, seasoning"]) == ["throb", "itch"])
        #expect(try ids(store, "symptoms", ["follows != curd"]) == ["throb"])
        #expect(try ids(store, "symptoms", ["onset_hours ~ 3"]) == ["throb"])
        #expect(throws: RecordStoreError.self) { try ids(store, "symptoms", ["label.x = 1"]) }   // not a link
    }

    @Test func groupsFollowLinksAndCountEachRecordOncePerGroup() throws {
        let store = try catalogue()
        func counts(_ by: String) throws -> [String: Decimal] {
            var out: [String: Decimal] = [:]
            for row in try store.query("symptoms", Query(aggregates: [.count], groupBy: [.field(by)])).rows {
                if case .number(let n)? = row["count"] { out[ValueDisplay.text(row[by] ?? .null)] = n }
            }
            return out
        }
        #expect(try counts("area.label") == ["Head": 2, "Gut": 1])
        #expect(try counts("follows") == ["brine": 1, "curd": 2, "oat": 1, "kernel": 1])
        // churn follows curd AND oat — one dairy, one grain; itch follows curd and kernel.
        #expect(try counts("follows.kind") == ["dairy": 2, "grain": 1, "nut": 1, "seasoning": 1])
        try store.update("churn", in: "symptoms", with: [:], adding: ["follows": ["kernel"]])
        // Two ingredients of churn are now... still one record per kind.
        let byKind = try store.query("symptoms", Query(filters: [Filter.parse("slug = churn")], aggregates: [.count], groupBy: [.field("follows.kind")]))
        #expect(byKind.rows.allSatisfy { $0["count"] == .number(1) })
    }
}

struct RangeTests {

    @Test func rangesReadTheWaysPeopleWriteThem() throws {
        let field = Field(name: "r", type: .range)
        func pair(_ value: JSONValue) throws -> [Database.Value] {
            try ValueCoercion.columns(for: value, field: field, now: Date(), timeZone: .current)
        }
        #expect(try pair(.array([.number(Decimal(string: "0.5")!), .number(3)])) == [.real(0.5), .real(3)])
        #expect(try pair(.string("1..2")) == [.real(1), .real(2)])
        #expect(try pair(.string("1 to 2")) == [.real(1), .real(2)])
        #expect(try pair(.object(["min": .number(1), "max": .string("4")])) == [.real(1), .real(4)])
        #expect(try pair(.number(2)) == [.real(2), .real(2)])
        #expect(throws: CoercionFailure.reason("the low end is above the high end")) { try pair(.string("3..1")) }
    }
}
