//
//  Provenance.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Where a record came from.
public struct Provenance: Codable, Sendable, Equatable {

    /// The file it was read from, if any.
    public var source: String?

    /// The SHA-256 of that file, hex — what makes a second copy a duplicate.
    public var sourceSHA256: String?

    /// The tool that produced it, e.g. `extract`.
    public var tool: String?

    public init(source: String? = nil, sourceSHA256: String? = nil, tool: String? = nil) {
        self.source = source
        self.sourceSHA256 = sourceSHA256
        self.tool = tool
    }
}
