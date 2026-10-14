//
//  Money.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// An exact amount: integer minor units and an ISO 4217 currency.
public struct Money: Sendable, Equatable, Hashable {

    /// Pence, cents, yen — whatever the currency's smallest unit is.
    public var minorUnits: Int64

    /// The ISO 4217 code, e.g. `GBP`.
    public var currency: String

    public init(minorUnits: Int64, currency: String) {
        self.minorUnits = minorUnits
        self.currency = currency
    }
}
