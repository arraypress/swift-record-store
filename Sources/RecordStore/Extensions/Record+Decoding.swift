//
//  Record+Decoding.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension Record {

    /// The record as an app's own type: its values (and `id`) decoded with
    /// datetimes as `Date` and money as ``Money``.
    func decoded<T: Decodable>(as type: T.Type) throws(RecordStoreError) -> T {
        var object = values
        object["id"] = .number(Decimal(id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: Data(JSONCoding.text(.object(object)).utf8))
        } catch {
            throw .unreadableJSON("record #\(id) does not decode as \(T.self): \(error)")
        }
    }
}
