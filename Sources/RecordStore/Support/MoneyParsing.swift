//
//  MoneyParsing.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Money in, money out. Accepts what people and extractors actually write —
//  "23.40 GBP", "GBP 23.40", "£23.40", "-£5", "1,234.56" (with the field's
//  currency), {amount, currency}, {minor, currency} — and never touches a
//  float: the amount goes through Decimal to integer minor units, and an
//  amount finer than the currency allows ("23.456 GBP") is refused rather
//  than rounded.
//

import Foundation

enum MoneyParsing {

    /// Reads a money value.
    ///
    /// - Parameters:
    ///   - value: what was given.
    ///   - defaultCurrency: the field's currency, used when the value names none.
    static func parse(_ value: JSONValue, defaultCurrency: String?) throws(MoneyFailure) -> Money {
        switch value {
        case .number(let amount):
            guard let currency = defaultCurrency else { throw .noCurrency }
            return try money(amount, currency: currency)
        case .string(let text):
            return try parse(text, defaultCurrency: defaultCurrency)
        case .object(let object):
            let currency: String
            switch object["currency"] {
            case .string(let code)?: currency = try code_(code)
            case nil, .null?:
                guard let fallback = defaultCurrency else { throw .noCurrency }
                currency = fallback
            default: throw .malformed("currency must be a string")
            }
            if case .number(let minor)? = object["minor"] {
                guard DecimalMath.isWhole(minor), let units = Int64(exactly: NSDecimalNumber(decimal: minor)) else {
                    throw .malformed("minor must be a whole number")
                }
                return Money(minorUnits: units, currency: currency)
            }
            switch object["amount"] {
            case .number(let amount)?: return try money(amount, currency: currency)
            case .string(let text)?: return try money(signedNumber(text), currency: currency)
            default: throw .malformed("give {\"amount\": …, \"currency\": …}")
            }
        default:
            throw .malformed("expected an amount such as \"23.40 GBP\"")
        }
    }

    /// Reads money written as text.
    static func parse(_ text: String, defaultCurrency: String?) throws(MoneyFailure) -> Money {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { throw .malformed("empty amount") }

        var negative = false
        if body.hasPrefix("(") && body.hasSuffix(")") {
            negative = true
            body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if body.hasPrefix("-") || body.hasPrefix("−") {
            negative.toggle()
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        var currency: String?

        // A three-letter code before or after the number.
        if let match = body.firstMatch(of: /^([A-Za-z]{3})\s*(.+)$/), Currencies.isKnown(String(match.1).uppercased()) {
            currency = String(match.1).uppercased()
            body = String(match.2)
        } else if let match = body.firstMatch(of: /^(.+?)\s*([A-Za-z]{3})$/), Currencies.isKnown(String(match.2).uppercased()) {
            currency = String(match.2).uppercased()
            body = String(match.1)
        }

        // A symbol before or after it, longest first so "R$" beats "$".
        if currency == nil {
            let symbols = (Array(Currencies.unambiguousSymbols.keys) + Array(Currencies.ambiguousSymbols.keys))
                .sorted { $0.count > $1.count }
            for symbol in symbols {
                let found: Bool
                if body.hasPrefix(symbol) {
                    body = String(body.dropFirst(symbol.count)); found = true
                } else if body.hasSuffix(symbol) {
                    body = String(body.dropLast(symbol.count)); found = true
                } else { found = false }
                guard found else { continue }
                if let code = Currencies.unambiguousSymbols[symbol] {
                    currency = code
                } else if let candidates = Currencies.ambiguousSymbols[symbol] {
                    guard let fallback = defaultCurrency, candidates.contains(fallback) else {
                        throw .ambiguousSymbol(symbol, candidates)
                    }
                    currency = fallback
                }
                break
            }
        }

        body = body.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("(") && body.hasSuffix(")") {
            negative.toggle()
            body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if body.hasPrefix("-") || body.hasPrefix("−") {
            negative.toggle()
            body = String(body.dropFirst())
        }
        guard let code = currency ?? defaultCurrency else { throw .noCurrency }
        let amount = try number(body)
        return try money(negative ? -amount : amount, currency: code)
    }

    /// A number that may carry a sign — "-60.00", "−60.00" — as in the {amount, currency} form store itself writes
    /// for a refund; without this, store couldn't read back its own negative amounts.
    static func signedNumber(_ text: String) throws(MoneyFailure) -> Decimal {
        let body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("-") || body.hasPrefix("−") { return -(try number(String(body.dropFirst()))) }
        return try number(body)
    }

    /// The amount part: digits, optional thousands commas, one decimal point.
    /// A lone comma followed by one or two digits is a decimal comma ("5,50").
    static func number(_ text: String) throws(MoneyFailure) -> Decimal {
        var digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        if !digits.contains("."), digits.filter({ $0 == "," }).count == 1,
           let comma = digits.firstIndex(of: ","), (1...2).contains(digits.distance(from: comma, to: digits.endIndex) - 1) {
            digits = digits.replacingOccurrences(of: ",", with: ".")
        } else {
            guard digits.wholeMatch(of: /\d{1,3}(,\d{3})*(\.\d+)?|\d+(\.\d+)?|\.\d+/) != nil else {
                throw .malformed("\"\(text)\" is not an amount")
            }
            digits = digits.replacingOccurrences(of: ",", with: "")
        }
        guard digits.wholeMatch(of: /\d*\.?\d+|\d+\./) != nil,
              let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else {
            throw .malformed("\"\(text)\" is not an amount")
        }
        return value
    }

    /// An amount in a currency, as exact minor units.
    static func money(_ amount: Decimal, currency: String) throws(MoneyFailure) -> Money {
        let code = try code_(currency)
        let exponent = Currencies.exponent(of: code)
        var scaled = amount * pow(Decimal(10), exponent)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw .tooPrecise(code, exponent) }
        guard let units = Int64(exactly: NSDecimalNumber(decimal: rounded)) else { throw .malformed("amount out of range") }
        return Money(minorUnits: units, currency: code)
    }

    /// Validates and uppercases a currency code.
    static func code_(_ code: String) throws(MoneyFailure) -> String {
        let upper = code.uppercased()
        guard Currencies.isKnown(upper) else { throw .unknownCurrency(code) }
        return upper
    }

    /// Minor units as a decimal string: 2340 GBP → "23.40", -500 JPY → "-500".
    static func amountText(_ money: Money) -> String {
        let exponent = Currencies.exponent(of: money.currency)
        let magnitude = money.minorUnits.magnitude
        guard exponent > 0 else { return (money.minorUnits < 0 ? "-" : "") + String(magnitude) }
        let divisor = UInt64(pow(10.0, Double(exponent)))
        let whole = magnitude / divisor
        let fraction = String(magnitude % divisor)
        return (money.minorUnits < 0 ? "-" : "") + "\(whole)." + String(repeating: "0", count: exponent - fraction.count) + fraction
    }

    /// The output form: `{"amount": "23.40", "currency": "GBP"}`.
    static func json(_ money: Money) -> JSONValue {
        .object(["amount": .string(amountText(money)), "currency": .string(money.currency)])
    }

    /// Divides exactly, rounding half away from zero to the currency's unit.
    static func average(_ total: Int64, count: Int, currency: String) -> Money {
        guard count > 0 else { return Money(minorUnits: 0, currency: currency) }
        var quotient = Decimal(total) / Decimal(count)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 0, .plain)
        return Money(minorUnits: Int64(truncating: NSDecimalNumber(decimal: rounded)), currency: currency)
    }
}

/// Why a money value was refused.
enum MoneyFailure: Error, Equatable {
    case noCurrency
    case unknownCurrency(String)
    case ambiguousSymbol(String, [String])
    case tooPrecise(String, Int)
    case malformed(String)

    var reason: String {
        switch self {
        case .noCurrency:
            return "no currency: write it (\"23.40 GBP\") or give the field a currency"
        case .unknownCurrency(let code):
            return "\"\(code)\" is not an ISO 4217 currency"
        case .ambiguousSymbol(let symbol, let candidates):
            return "\"\(symbol)\" could be \(candidates.joined(separator: ", ")): write the code (\"5 \(candidates[0])\") or give the field a currency"
        case .tooPrecise(let code, let exponent):
            return exponent == 0
                ? "\(code) has no minor unit: give a whole amount"
                : "\(code) has \(exponent) decimal places: the amount is finer than that"
        case .malformed(let detail):
            return detail
        }
    }
}
