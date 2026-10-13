//
//  ResultTable.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Rows with named columns — what a query or a raw SQL statement returns.
public struct ResultTable: Sendable, Equatable {

    /// Column names, in display order.
    public var columns: [String]

    /// One value per column name.
    public var rows: [[String: JSONValue]]

    public init(columns: [String], rows: [[String: JSONValue]]) {
        self.columns = columns
        self.rows = rows
    }
}
