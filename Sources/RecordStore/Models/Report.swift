//
//  Report.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A report, assembled: what ``ReportSpec`` asked for, with the numbers in.
/// `markdown` sets it as a document.
public struct Report: Sendable, Equatable {

    public var title: String

    /// The collection reported on.
    public var collection: String

    /// The first and last day covered (`YYYY-MM-DD`), when there are records
    /// or a period was given.
    public var from: String?
    public var to: String?

    /// Records in the report.
    public var count: Int

    /// When it was made, UTC ISO 8601.
    public var generatedAt: String

    /// A paragraph under the title.
    public var notes: String?

    /// Tables, in order: overall, per bucket, top values, what came before,
    /// and the log.
    public var sections: [Section]

    public init(title: String, collection: String, from: String?, to: String?, count: Int, generatedAt: String,
                notes: String?, sections: [Section]) {
        self.title = title
        self.collection = collection
        self.from = from
        self.to = to
        self.count = count
        self.generatedAt = generatedAt
        self.notes = notes
        self.sections = sections
    }

    /// One titled table, with an optional sentence before it.
    public struct Section: Sendable, Equatable {
        public var title: String
        public var note: String?
        public var table: ResultTable

        /// Column headings for people, by column; the rest are derived
        /// (`severity_avg` → "average severity").
        public var headings: [String: String]

        public init(title: String, note: String? = nil, table: ResultTable, headings: [String: String] = [:]) {
            self.title = title
            self.note = note
            self.table = table
            self.headings = headings
        }
    }
}
