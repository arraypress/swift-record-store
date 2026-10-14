//
//  RecordStore+SwiftSource.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension RecordStore {

    /// Swift source for a struct matching `collection` — what `store schema
    /// NAME --emit swift` prints. Links are typed by their target: keys as
    /// `String`, ids as `Int64`.
    func swiftSource(for collection: String, typeName: String? = nil) throws(RecordStoreError) -> String {
        SwiftEmitting.source(try schema(named: collection), typeName: typeName, targets: try catalog())
    }
}
