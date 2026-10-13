//
//  Currencies.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  ISO 4217 facts the money parser needs: how many minor-unit digits each
//  currency has, and which symbols name exactly one currency. `$`, `¥` and
//  `kr` name several, so they are accepted only when the field says which.
//

import Foundation

enum Currencies {

    /// Currencies whose minor unit is not hundredths.
    private static let exponents: [String: Int] = [
        "BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0,
        "PYG": 0, "RWF": 0, "UGX": 0, "UYI": 0, "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
        "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
        "CLF": 4, "UYW": 4,
    ]

    /// Symbols that name exactly one currency.
    static let unambiguousSymbols: [String: String] = [
        "£": "GBP", "€": "EUR", "₹": "INR", "₩": "KRW", "₺": "TRY", "₽": "RUB", "₪": "ILS",
        "฿": "THB", "₫": "VND", "₱": "PHP", "₴": "UAH", "₦": "NGN", "zł": "PLN", "R$": "BRL",
        "C$": "CAD", "A$": "AUD", "NZ$": "NZD", "HK$": "HKD", "S$": "SGD", "US$": "USD", "Kč": "CZK",
    ]

    /// Symbols that could be several currencies.
    static let ambiguousSymbols: [String: [String]] = [
        "$": ["USD", "CAD", "AUD", "NZD", "HKD", "SGD", "MXN"],
        "¥": ["JPY", "CNY"],
        "kr": ["SEK", "NOK", "DKK", "ISK"],
    ]

    /// Whether a code is a real ISO 4217 currency.
    static func isKnown(_ code: String) -> Bool {
        known.contains(code)
    }

    /// Digits after the decimal point for a currency.
    static func exponent(of code: String) -> Int {
        exponents[code] ?? 2
    }

    private static let known: Set<String> = Set(Locale.Currency.isoCurrencies.map(\.identifier))
}
