//
//  Money+Codable.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

extension Money: Codable {

    private enum CodingKeys: String, CodingKey {
        case amount, currency, minorUnits
    }

    /// Reads money the way records give it out — `{"amount": "23.40",
    /// "currency": "GBP"}` — or as `{"minorUnits": 2340, "currency": "GBP"}`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try c.decode(String.self, forKey: .currency)
        if let minor = try c.decodeIfPresent(Int64.self, forKey: .minorUnits) {
            self.init(minorUnits: minor, currency: currency)
            return
        }
        let amount = try c.decode(String.self, forKey: .amount)
        do {
            self = try MoneyParsing.parse("\(amount) \(currency)", defaultCurrency: currency)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: c, debugDescription: error.reason)
        }
    }

    /// Writes `{"amount": "23.40", "currency": "GBP"}`, as records do.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(MoneyParsing.amountText(self), forKey: .amount)
        try c.encode(currency, forKey: .currency)
    }
}
