//
//  JournalAction.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What a journal entry recorded.
public enum JournalAction: String, Codable, Sendable {
    case define
    case insert
    case update
    case delete
    case migrate
}
