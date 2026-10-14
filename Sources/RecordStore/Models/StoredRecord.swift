//
//  StoredRecord.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A Swift type an app reads a collection into — what `store schema NAME
/// --emit swift` writes. Fields decode from the values a ``Record`` holds:
/// money as ``Money``, datetimes as `Date`, dates as `YYYY-MM-DD` text, tags
/// and links as arrays, a range as `[Double]`.
///
/// ```swift
/// let symptoms = try store.fetch(Symptom.self)
/// ```
public protocol StoredRecord: Decodable {

    /// The collection the type is read from.
    static var collection: String { get }
}
