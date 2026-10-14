//
//  ParsingTests.swift
//  RecordStoreTests
//
//  Created by David Sherlock on 2026.
//

import Foundation
import Testing
@testable import RecordStore

struct MoneyParsingTests {

    @Test(arguments: [
        ("23.40 GBP", nil as String?, Int64(2340), "GBP"),
        ("GBP 23.40", nil, 2340, "GBP"),
        ("£23.40", nil, 2340, "GBP"),
        ("€5", nil, 500, "EUR"),
        ("1,234.56", "GBP", 123456, "GBP"),
        ("-£5", nil, -500, "GBP"),
        ("£-5.25", nil, -525, "GBP"),
        ("(12.00) USD", nil, -1200, "USD"),
        ("JPY 500", nil, 500, "JPY"),
        ("¥500", "JPY", 500, "JPY"),
        ("$19.99", "USD", 1999, "USD"),
        ("5,50 EUR", nil, 550, "EUR"),
        ("1.250 KWD", nil, 1250, "KWD"),
        ("R$ 10", nil, 1000, "BRL"),
        ("usd 3", nil, 300, "USD"),
    ])
    func readsWhatPeopleWrite(text: String, currency: String?, minor: Int64, code: String) throws {
        let money = try MoneyParsing.parse(text, defaultCurrency: currency)
        #expect(money == Money(minorUnits: minor, currency: code))
    }

    @Test func refusesWhatCannotBeKnown() {
        #expect(throws: MoneyFailure.noCurrency) { try MoneyParsing.parse("1,234.56", defaultCurrency: nil) }
        #expect(throws: MoneyFailure.ambiguousSymbol("$", ["USD", "CAD", "AUD", "NZD", "HKD", "SGD", "MXN"])) {
            try MoneyParsing.parse("$5", defaultCurrency: nil)
        }
        #expect(throws: MoneyFailure.tooPrecise("GBP", 2)) { try MoneyParsing.parse("23.456 GBP", defaultCurrency: nil) }
        #expect(throws: MoneyFailure.tooPrecise("JPY", 0)) { try MoneyParsing.parse("JPY 500.5", defaultCurrency: nil) }
        #expect(throws: MoneyFailure.unknownCurrency("XYZ")) { try MoneyParsing.parse(.object(["amount": .number(1), "currency": .string("XYZ")]), defaultCurrency: nil) }
        #expect(throws: (any Error).self) { try MoneyParsing.parse("twelve quid", defaultCurrency: "GBP") }
    }

    @Test func numbersAndObjectsNeverTouchAFloat() throws {
        // 0.1 + 0.2 territory: a Double would make 23.40 into 2339 pence.
        let parsed = try JSONCoding.parse(#"{"a": 23.40, "b": 0.29}"#)
        guard case .object(let o) = parsed else { Issue.record("not an object"); return }
        #expect(try MoneyParsing.parse(o["a"]!, defaultCurrency: "GBP").minorUnits == 2340)
        #expect(try MoneyParsing.parse(o["b"]!, defaultCurrency: "GBP").minorUnits == 29)
        #expect(try MoneyParsing.parse(.object(["minor": .number(2340), "currency": .string("gbp")]), defaultCurrency: nil) == Money(minorUnits: 2340, currency: "GBP"))
        #expect(try MoneyParsing.parse(.object(["amount": .string("1,000.10"), "currency": .string("EUR")]), defaultCurrency: nil).minorUnits == 100010)
    }

    @Test func amountTextKeepsTheCurrencysDigits() {
        #expect(MoneyParsing.amountText(Money(minorUnits: 2340, currency: "GBP")) == "23.40")
        #expect(MoneyParsing.amountText(Money(minorUnits: -5, currency: "GBP")) == "-0.05")
        #expect(MoneyParsing.amountText(Money(minorUnits: 500, currency: "JPY")) == "500")
        #expect(MoneyParsing.amountText(Money(minorUnits: 1250, currency: "KWD")) == "1.250")
        #expect(MoneyParsing.average(1001, count: 2, currency: "GBP").minorUnits == 501)
    }
}

struct DateParsingTests {

    let now = Date(timeIntervalSince1970: 1_791_900_000) // 2026-10-13 UTC
    let utc = TimeZone(secondsFromGMT: 0)!

    @Test(arguments: [
        ("2026-10-13", "2026-10-13"), ("2026/10/3", "2026-10-03"), ("20261013", "2026-10-13"),
        ("13 Oct 2026", "2026-10-13"), ("13th October 2026", "2026-10-13"), ("October 13, 2026", "2026-10-13"),
        ("25/12/2026", "2026-12-25"), ("12/25/2026", "2026-12-25"), ("2026-10-13T23:30:00+05:00", "2026-10-13"),
        ("2024-02-29", "2024-02-29"),
    ])
    func dates(text: String, expected: String) throws {
        #expect(try DateParsing.date(text, now: now, timeZone: utc) == expected)
    }

    @Test func relativeDates() throws {
        #expect(try DateParsing.date("today", now: now, timeZone: utc) == "2026-10-13")
        #expect(try DateParsing.date("yesterday", now: now, timeZone: utc) == "2026-10-12")
    }

    @Test func refusals() {
        #expect(throws: DateFailure.ambiguous("03/04/2026")) { try DateParsing.date("03/04/2026", now: now, timeZone: utc) }
        #expect(throws: DateFailure.invalid("2026-02-29")) { try DateParsing.date("2026-02-29", now: now, timeZone: utc) }
        #expect(throws: DateFailure.unreadable("soon")) { try DateParsing.date("soon", now: now, timeZone: utc) }
    }

    @Test func datetimesBecomeUTC() throws {
        #expect(try DateParsing.datetime("2026-10-13T09:30:00+01:00", now: now, timeZone: utc) == "2026-10-13T08:30:00Z")
        #expect(try DateParsing.datetime("2026-10-13 09:30", now: now, timeZone: TimeZone(secondsFromGMT: 3600)!) == "2026-10-13T08:30:00Z")
        #expect(try DateParsing.datetime("2026-10-13", now: now, timeZone: utc) == "2026-10-13T00:00:00Z")
    }
}

struct SchemaParsingTests {

    @Test func shorthandAndObjectsMix() throws {
        let schema = try Schema.parse(#"""
            {"name": "expenses", "fields": [
                "shop:text!", "total:money(gbp)!",
                {"name": "date", "type": "date", "required": true},
                "category:choice(groceries|fuel|eating out)",
                {"name": "tags", "type": "tags", "description": "free labels"}
            ]}
            """#)
        #expect(schema.fields.map(\.name) == ["shop", "total", "date", "category", "tags"])
        #expect(schema.fields[1].currency == "GBP" && schema.fields[1].required)
        #expect(schema.fields[3].choices == ["groceries", "fuel", "eating out"])
    }

    @Test func choicesSplitOnCommasWhenThereIsNoBar() throws {
        // `choice(a,b)` used to be ONE choice "a,b" that no value matched.
        #expect(try SchemaRules.field(fromSpec: "c:choice(food, travel,bills)").choices == ["food", "travel", "bills"])
        #expect(try SchemaRules.field(fromSpec: "c:choice(salt, pepper|oil)").choices == ["salt, pepper", "oil"])
    }

    @Test func badSchemasSayWhy() {
        func reason(_ text: String) -> String {
            do { _ = try Schema.parse(text); return "" } catch { return error.message }
        }
        #expect(reason(#"{"name": "Expenses", "fields": ["a:text"]}"#).contains("not a usable name"))
        #expect(reason(#"{"name": "e", "fields": ["id:text"]}"#).contains("\"id\" is taken"))
        #expect(reason(#"{"name": "e", "fields": ["a:text", "a:number"]}"#).contains("appears twice"))
        #expect(reason(#"{"name": "e", "fields": ["c:choice"]}"#).contains("needs \"choices\""))
        #expect(reason(#"{"name": "e", "fields": [{"name": "a", "type": "txt"}]}"#).contains("needs a \"type\""))
        #expect(reason(#"{"name": "e", "fields": [{"name": "a", "type": "text", "requird": true}]}"#).contains("unknown key \"requird\""))
        #expect(reason(#"{"name": "e", "fields": ["n:integer=abc"]}"#).contains("default"))
    }

    @Test func filters() throws {
        #expect(try Filter.parse("total > 20 GBP") == Filter(field: "total", op: .greater, value: "20 GBP"))
        #expect(try Filter.parse("shop in Tesco, Aldi") == Filter(field: "shop", op: .oneOf, value: "Tesco, Aldi"))
        #expect(try Filter.parse("notes != \"x y\"") == Filter(field: "notes", op: .notEqual, value: "x y"))
        #expect(try Filter.parse("tags~work") == Filter(field: "tags", op: .contains, value: "work"))
        #expect(throws: RecordStoreError.self) { try Filter.parse("total is big") }
    }
}
