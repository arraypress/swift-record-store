//
//  QueryTests.swift
//  RecordStoreTests
//
//  Created by David Sherlock on 2026.
//

import Foundation
import Testing
@testable import RecordStore

/// Expenses with known totals: Sept 30.00 GBP; Oct 12.50 + 7.25 GBP and 10 EUR.
func seeded() throws -> RecordStore {
    let store = try makeStore()
    let rows = try JSONValue.parseRecords("""
        {"shop": "Tesco", "total": "20.00 GBP", "date": "2026-09-05", "category": "groceries", "tags": ["food"]}
        {"shop": "Shell", "total": "10.00 GBP", "date": "2026-09-20", "category": "fuel"}
        {"shop": "Tesco", "total": "12.50 GBP", "date": "2026-10-02", "category": "groceries", "tags": ["food", "weekly"]}
        {"shop": "Aldi", "total": "7.25", "date": "2026-10-09", "category": "groceries"}
        {"shop": "Carrefour", "total": "€10", "date": "2026-10-11", "category": "groceries", "tags": ["holiday"]}
        """)
    try store.addAll(rows.map { ($0.line, $0.value) }, to: "expenses")
    return store
}

func money(_ amount: String, _ currency: String) -> JSONValue {
    .object(["amount": .string(amount), "currency": .string(currency)])
}

struct QueryTests {

    @Test func filters() throws {
        let store = try seeded()
        func ids(_ filters: [String], since: String? = nil, until: String? = nil) throws -> [JSONValue] {
            try store.query("expenses", Query(filters: filters.map(Filter.parse), since: since, until: until)).rows.map { $0["id"]! }
        }
        #expect(try ids(["shop = Tesco"]) == [.number(1), .number(3)])
        #expect(try ids(["total > 11 GBP"]) == [.number(1), .number(3)])
        #expect(try ids(["total <= 10 EUR"]) == [.number(5)])
        #expect(try ids(["tags ~ food"]) == [.number(1), .number(3)])
        #expect(try ids(["shop ~ sc"]) == [.number(1), .number(3)])
        #expect(try ids(["category in fuel, Groceries", "shop != Tesco"]) == [.number(2), .number(4), .number(5)])
        #expect(try ids(["tags = null"]) == [.number(2), .number(4)])
        #expect(try ids([], since: "1 Oct 2026") == [.number(3), .number(4), .number(5)])
        #expect(try ids([], since: "2026-09-01", until: "2026-09-30") == [.number(1), .number(2)])
        #expect(try ids(["date >= 2026-10-09"]) == [.number(4), .number(5)])
    }

    @Test func sumsAreExactAndNeverCrossCurrencies() throws {
        let store = try seeded()
        let result = try store.query("expenses", Query(aggregates: [.sum("total"), .count]))
        #expect(result.columns == ["total_sum", "count"])
        #expect(Set(result.rows.map { $0["total_sum"]! }) == [money("49.75", "GBP"), money("10.00", "EUR")])
        let gbp = result.rows.first { $0["total_sum"] == money("49.75", "GBP") }!
        #expect(gbp["count"] == .number(4))
    }

    @Test func groupedByMonthAndCategory() throws {
        let store = try seeded()
        let result = try store.query("expenses", Query(
            filters: [Filter(field: "total", op: .greaterOrEqual, value: "0 GBP")],
            aggregates: [.sum("total"), .average("total")], groupBy: [.period(.month), .field("category")]))
        #expect(result.columns == ["month", "category", "total_sum", "total_avg"])
        let rows = result.rows.map { "\($0["month"]!.displayText) \($0["category"]!.displayText) \($0["total_sum"]!.displayText) \($0["total_avg"]!.displayText)" }
        #expect(rows == [
            "2026-09 fuel 10.00 GBP 10.00 GBP",
            "2026-09 groceries 20.00 GBP 20.00 GBP",
            "2026-10 groceries 19.75 GBP 9.88 GBP",
        ])
    }

    @Test func groupedByTagsCountsEachRecordUnderEveryTag() throws {
        let store = try seeded()
        let result = try store.query("expenses", Query(aggregates: [.count, .sum("total")], groupBy: [.field("tags")]))
        #expect(result.columns == ["tags", "count", "total_sum"])
        let rows = result.rows.map { "\($0["tags"]!.displayText) \($0["count"]!.displayText) \($0["total_sum"]!.displayText)" }
        // Records with no tags are in no group; record 3 counts under both of its tags.
        #expect(rows == ["food 2 32.50 GBP", "holiday 1 10.00 EUR", "weekly 1 12.50 GBP"])

        let filtered = try store.query("expenses", Query(filters: ["shop = Tesco"].map(Filter.parse), groupBy: [.field("tags"), .period(.month)]))
        #expect(filtered.rows.map { "\($0["tags"]!.displayText) \($0["month"]!.displayText) \($0["count"]!.displayText)" }
                == ["food 2026-09 1", "food 2026-10 1", "weekly 2026-10 1"])
    }

    @Test func aFieldNameSortsByItsOnlyAggregate() throws {
        let store = try seeded()
        let byTotal = try store.query("expenses", Query(filters: ["total > 0 GBP"].map(Filter.parse), aggregates: [.sum("total")],
                                                        groupBy: [.field("shop")], order: [Ordering(key: "total", descending: true)]))
        #expect(byTotal.rows.map { $0["shop"]!.displayText } == ["Tesco", "Shell", "Aldi"])
        #expect(throws: RecordStoreError.self) {
            try store.query("expenses", Query(aggregates: [.sum("total"), .average("total")], groupBy: [.field("shop")],
                                              order: [Ordering(key: "total", descending: true)]))
        }
    }

    @Test func runningTotalsOverRecordsAndOverGroups() throws {
        let store = try seeded()
        let records = try store.query("expenses", Query(running: "total"))
        #expect(records.rows.map { $0["total_running"]!.displayText } == ["20.00 GBP", "30.00 GBP", "42.50 GBP", "49.75 GBP", "10.00 EUR"])

        let monthly = try store.query("expenses", Query(filters: [Filter(field: "total", op: .greater, value: "0 GBP")],
                                                        groupBy: [.period(.month)], running: "total"))
        #expect(monthly.columns == ["month", "total_sum", "total_running"])
        #expect(monthly.rows.map { $0["total_running"]!.displayText } == ["30.00 GBP", "49.75 GBP"])
    }

    @Test func orderLimitAndMinMax() throws {
        let store = try seeded()
        let top = try store.query("expenses", Query(order: [Ordering(key: "total", descending: true)], limit: 2))
        #expect(top.rows.map { $0["id"]! } == [.number(1), .number(3)])
        let extremes = try store.query("expenses", Query(aggregates: [.minimum("date"), .maximum("date")]))
        #expect(extremes.rows.first?["date_min"] == .string("2026-09-05"))
        #expect(extremes.rows.first?["date_max"] == .string("2026-10-11"))
        let byCount = try store.query("expenses", Query(aggregates: [.count], groupBy: [.field("shop")], order: [Ordering(key: "count", descending: true)], limit: 1))
        #expect(byCount.rows == [["shop": .string("Tesco"), "count": .number(2)]])
    }

    @Test func badQueriesSayWhy() throws {
        let store = try seeded()
        #expect(throws: RecordStoreError.invalidQuery("shop is text — a sum needs a number, integer or money field")) {
            try store.query("expenses", Query(aggregates: [.sum("shop")]))
        }
        #expect(throws: RecordStoreError.unknownField(collection: "expenses", field: "nope")) {
            try store.query("expenses", Query(filters: [Filter(field: "nope", op: .equal, value: "1")]))
        }
    }
}
