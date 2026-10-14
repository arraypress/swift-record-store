//
//  WindowTests.swift
//  RecordStoreTests
//
//  Created by David Sherlock on 2026.
//
//  A made-up diary with a known answer. Brine is in EVERY meal, so it
//  precedes every symptom — and must not top the list for that. Curd is in
//  a third of the meals but in every meal eaten in the hour or two before a
//  "churn". The ratio has to put curd first and brine at 1.
//

import Foundation
import Testing
@testable import RecordStore

/// The catalogue plus `meals` and `log`, over two weeks.
func diary() throws -> RecordStore {
    let store = try catalogue()
    try store.define(Schema.parse(#"{"name": "meals", "fields": ["name:text!", "eaten:datetime!", "has:refs(ingredients)", "tags:tags"]}"#))
    try store.define(Schema.parse(#"{"name": "log", "fields": ["symptom:ref(symptoms)!", "felt:datetime!", "severity:integer"]}"#))
    var meals: [(Int, [String: JSONValue])] = []
    var log: [(Int, [String: JSONValue])] = []
    // Day d: breakfast 08:00 (oat, brine), lunch 13:00 (brine, kernel on odd days),
    // and on days 1, 4, 7, 10, 13 a curd supper at 19:00 followed by churn at 20:30.
    for d in 1...14 {
        let day = String(format: "2026-09-%02d", d)
        meals.append((meals.count + 1, ["name": .string("porridge"), "eaten": .string("\(day)T08:00:00Z"),
                                        "has": .array([.string("oat"), .string("brine")]), "tags": .array([.string("Breakfast")])]))
        meals.append((meals.count + 1, ["name": .string("soup"), "eaten": .string("\(day)T13:00:00Z"),
                                        "has": .array(d % 2 == 1 ? [.string("brine"), .string("kernel")] : [.string("brine")])]))
        if d % 3 == 1 {
            meals.append((meals.count + 1, ["name": .string("curd pie"), "eaten": .string("\(day)T19:00:00Z"),
                                            "has": .array([.string("curd"), .string("brine")]), "tags": .array([.string("supper")])]))
            log.append((log.count + 1, ["symptom": .string("churn"), "felt": .string("\(day)T20:30:00Z"), "severity": .number(3)]))
        }
    }
    // A throb at 15:00 on day 2: lunch (brine) two hours before, inside throb's own 1–4 h.
    log.append((log.count + 1, ["symptom": .string("throb"), "felt": .string("2026-09-02T15:00:00Z"), "severity": .number(2)]))
    try store.addAll(meals, to: "meals")
    try store.addAll(log, to: "log")
    return store
}

struct WindowTests {

    func row(_ analysis: WindowAnalysis, _ value: String, field: String? = nil) -> [String: JSONValue]? {
        analysis.table.rows.first { ValueDisplay.text($0["value"] ?? .null).lowercased() == value && (field == nil || $0["field"] == .string(field!)) }
    }

    @Test func theRatioPutsTheRareCulpritFirstAndTheUbiquitousAtOne() throws {
        let store = try diary()
        let analysis = try store.window(WindowSpec(events: "log", exposures: "meals", within: .fixed(from: 0, to: 3 * 3600), tally: ["has"]))
        #expect(analysis.events == 6)
        #expect(analysis.covered == 6)
        #expect(analysis.exposures == 33)
        #expect(analysis.matched == 6)   // five curd pies and the day-2 soup
        let curd = try #require(row(analysis, "curd"))
        let brine = try #require(row(analysis, "brine"))
        #expect(curd["events"] == .number(5))
        #expect(curd["all"] == .number(5))
        #expect(brine["events"] == .number(6))         // brine precedes everything...
        #expect(brine["ratio"] == .number(1))          // ...because it is in everything
        #expect(analysis.table.rows.first?["value"] == .string("curd"))
        // curd: 5 of 6 meals in windows vs 5 of 33 at all → (5/6)/(5/33) = 5.5
        #expect(curd["ratio"] == .number(Decimal(string: "5.5")!))
        #expect(row(analysis, "oat") == nil)           // breakfast is never in a window
    }

    @Test func eachRecordCanReadItsOwnWindowThroughALink() throws {
        let store = try diary()
        // churn: 0.5–2 h, throb: 1–4 h — read from the symptom each log entry links to.
        let analysis = try store.window(WindowSpec(events: "log", exposures: "meals", within: .field("symptom.onset_hours", unit: 3600),
                                                   tally: ["has", "has.kind"], minEvents: 1))
        #expect(analysis.covered == 6)
        #expect(row(analysis, "dairy", field: "has.kind")?["events"] == .number(5))
        #expect(row(analysis, "kernel")?["events"] == nil || row(analysis, "kernel")?["events"] == .number(0))
        // A window that starts later than a meal: churn's 0.5 h minimum excludes a meal 20 minutes before.
        try store.add(json(#"{"name": "snack", "eaten": "2026-09-03T20:10:00Z", "has": ["kernel"]}"#), to: "meals")
        try store.add(json(#"{"symptom": "churn", "felt": "2026-09-03T20:30:00Z"}"#), to: "log")
        let later = try store.window(WindowSpec(events: "log", exposures: "meals", within: .field("symptom.onset_hours", unit: 3600), tally: ["has"]))
        #expect(later.events == 7 && later.covered == 6)
    }

    @Test func filtersPeriodsAndMinimums() throws {
        let store = try diary()
        let throbOnly = try store.window(WindowSpec(events: "log", filters: [Filter.parse("symptom = throb")], exposures: "meals",
                                                    within: .fixed(from: 3600, to: 4 * 3600), tally: ["has"]))
        #expect(throbOnly.events == 1 && throbOnly.matched == 1)
        #expect(row(throbOnly, "brine")?["events"] == .number(1))
        let firstWeek = try store.window(WindowSpec(events: "log", exposures: "meals", until: "2026-09-07",
                                                    within: .fixed(from: 0, to: 3 * 3600), tally: ["has"], minEvents: 4))
        #expect(firstWeek.events == 4)
        #expect(firstWeek.table.rows.map { ValueDisplay.text($0["value"]!) }.sorted() == ["brine"])   // curd precedes 3, under the minimum
        #expect(throws: RecordStoreError.self) {
            try store.window(WindowSpec(events: "log", exposures: "meals", within: .field("severity", unit: 3600), tally: ["has"]))
        }
    }

    @Test func windowsAreWrittenTheWayPeopleSayThem() throws {
        #expect(try WindowSpec.Window.parse("30m..3h") == .fixed(from: 1800, to: 10_800))
        #expect(try WindowSpec.Window.parse("0..3h") == .fixed(from: 0, to: 10_800))
        #expect(try WindowSpec.Window.parse("2h") == .fixed(from: 0, to: 7200))
        #expect(try WindowSpec.Window.parse("symptom.onset_hours") == .field("symptom.onset_hours", unit: 3600))
        #expect(try WindowSpec.Window.parse("symptom.onset", unit: "minutes") == .field("symptom.onset", unit: 60))
        #expect(throws: RecordStoreError.self) { try WindowSpec.Window.parse("3h..30m") }
        #expect(throws: RecordStoreError.self) { try WindowSpec.Window.parse("3 fortnights") }
        #expect(WindowSpec.Window.fixed(from: 1800, to: 10_800).text == "30m..3h")
    }
}

struct ReportTests {

    @Test func aReportHasThePeriodTheTablesAndTheLog() throws {
        let store = try diary()
        let spec = ReportSpec(title: "Churn diary", filters: [try Filter.parse("symptom = churn")], since: "2026-09-01", until: "2026-09-14",
                              averages: ["severity"], top: ["symptom.area"], columns: ["felt", "symptom", "severity"],
                              window: .init(exposures: "meals", within: .fixed(from: 0, to: 3 * 3600), tally: ["has"], minEvents: 2),
                              notes: "Made-up data.")
        let report = try store.report("log", spec)
        #expect(report.count == 5)
        #expect(report.from == "2026-09-01" && report.to == "2026-09-14")
        #expect(report.sections.map(\.title) == ["Overall", "By week", "Most common symptom.area", "What came before", "Log"])
        #expect(report.sections[0].table.rows.first?["severity_avg"] == .number(3))
        let markdown = report.markdown()
        #expect(markdown.hasPrefix("---\ntitle: \"Churn diary\"\nsubtitle: \"1 Sep 2026 to 14 Sep 2026 · 5 records\""))
        #expect(markdown.contains("| felt | symptom | severity |"))
        #expect(markdown.contains("| 2026-09-01 20:30 | churn | 3 |"))
        #expect(markdown.contains("| has | records after | share of records | share of meals before | share of all meals | ratio |"))
        #expect(markdown.contains("not what caused it"))
        #expect(!report.markdown(frontMatter: false).contains("---\ntitle"))
    }

    @Test func aReportSavedWithTheSchemaRunsByName() throws {
        let store = try diary()
        let spec = ReportSpec(name: "weekly", title: "Every week", last: "14d", every: .week, averages: ["severity"])
        try store.migrate("log", .saveReport(spec))
        #expect(try store.schema(named: "log").reports == [spec])
        store.now = { Date(timeIntervalSince1970: 1_789_430_400) }   // 2026-09-15
        let report = try store.report("log", saved: "weekly")
        #expect(report.title == "Every week")
        #expect(report.from == "2026-09-02" && report.to == "2026-09-15")
        #expect(report.count == 5)   // days 2–14: churns on 4, 7, 10, 13 and the throb on 2
        #expect(throws: RecordStoreError.self) { try store.migrate("log", .saveReport(ReportSpec(name: "bad", averages: ["symptom"]))) }
        try store.undo()
        #expect(try store.schema(named: "log").reports == nil)
        // Saved specs read from JSON with filters as text and the window as words.
        let decoded = try JSONCoding.decode(ReportSpec.self, from: #"{"name": "m", "filters": ["severity > 2"], "window": {"exposures": "meals", "within": "30m..3h", "tally": ["has"]}}"#)
        #expect(decoded.filters == [Filter(field: "severity", op: .greater, value: "2")])
        #expect(decoded.window?.within == .fixed(from: 1800, to: 10_800) && decoded.window?.minEvents == 2)
    }
}

/// What `store schema symptoms --emit swift` writes, checked by decoding
/// real records into the same shape.
struct Symptom: StoredRecord, Equatable {
    static let collection = "symptoms"
    var id: Int64
    var slug: String
    var label: String
    var area: String
    var follows: [String]?
    var onsetHours: [Double]?

    enum CodingKeys: String, CodingKey {
        case id, slug, label, area, follows
        case onsetHours = "onset_hours"
    }
}

struct CodegenTests {

    @Test func theEmittedStructMatchesTheTable() throws {
        let store = try diary()
        let source = try store.swiftSource(for: "symptoms")
        #expect(source.contains("struct Symptom: StoredRecord, Sendable, Equatable {"))
        #expect(source.contains("    static let collection = \"symptoms\""))
        #expect(source.contains("    var area: String\n"))
        #expect(source.contains("    var follows: [String]?\n"))
        #expect(source.contains("    var onsetHours: [Double]?\n"))
        #expect(source.contains("        case onsetHours = \"onset_hours\""))
        let ingredients = try store.swiftSource(for: "ingredients")
        #expect(ingredients.contains("struct Ingredient"))
        #expect(ingredients.contains("    enum Kind: String, Codable, CaseIterable, Sendable {"))
        let expenses = try makeStore().swiftSource(for: "expenses")
        #expect(expenses.contains("    var total: Money\n") && expenses.contains("        case eatingOut = \"eating out\""))
        #expect(SwiftEmitting.typeName(for: "daily_entries") == "DailyEntry")

        let symptoms = try store.fetch(Symptom.self, Query(filters: [Filter.parse("slug = churn")]))
        #expect(symptoms == [Symptom(id: 2, slug: "churn", label: "Churn", area: "gut", follows: ["curd", "oat"], onsetHours: [0.5, 2])])
    }

    @Test func moneyAndDatesDecode() throws {
        struct Expense: StoredRecord {
            static let collection = "expenses"
            var id: Int64
            var shop: String
            var total: Money
            var date: String
        }
        struct Meal: StoredRecord {
            static let collection = "meals"
            var id: Int64
            var eaten: Date
        }
        let store = try seeded()
        let first = try #require(try store.fetch(Expense.self).first)
        #expect(first.total == Money(minorUnits: 2000, currency: "GBP") && first.date == "2026-09-05")
        let meal = try #require(try diary().fetch(Meal.self).first)
        #expect(meal.eaten == Date(timeIntervalSince1970: 1_788_249_600))   // 2026-09-01T08:00:00Z
    }
}

struct CompatibilityTests {

    /// A database written by store 0.1.1 (library 0.1.2): it opens, reads,
    /// takes writes, undoes its own old entries and gains a key.
    @Test func aVersionZeroOneDatabaseKeepsWorking() throws {
        let fixture = try #require(Bundle.module.url(forResource: "v0.1.2", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).sqlite").path
        try FileManager.default.copyItem(atPath: fixture.path, toPath: path)
        let store = try RecordStore(path: path)
        #expect(try store.schemas().map(\.name) == ["expenses", "meals"])
        #expect(try store.schema(named: "meals").key == nil)
        let meals = try store.query("meals", Query(aggregates: [.count], groupBy: [.field("allergens")]))
        #expect(meals.rows == [["allergens": .string("gluten"), "count": .number(2)]])
        #expect(try store.get(2, from: "meals").values["symptoms"] == .array([.string("bloating")]))
        #expect(try store.get(1, from: "expenses").values["total"] == money("23.40", "GBP"))
        // The old journal: its newest live entry (the symptom added to meal 2) still undoes.
        let undone = try store.undo()
        #expect(undone.action == .update && undone.batch == nil)
        #expect(try store.get(2, from: "meals").values["symptoms"] == .null)
        // New writes and new features on old collections.
        try store.add(json(#"{"shop": "Aldi", "total": "2 GBP", "date": "2026-10-14"}"#), to: "expenses")
        try store.migrate("expenses", .setKey("shop"))
        #expect(try store.get("aldi", from: "expenses").values["total"] == money("2.00", "GBP"))
        #expect(try store.check().isEmpty)
        // And the file reopens.
        #expect(try RecordStore(path: path).count(in: "expenses") == 2)
    }
}
