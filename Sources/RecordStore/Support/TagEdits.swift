//
//  TagEdits.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Adding to and removing from a tag list without restating it.
enum TagEdits {

    /// `have` with `adding` appended (a tag already there, in any case, is not
    /// added twice) and every tag in `removing` taken out, matched without case.
    static func applied(_ have: [String], adding: [String], removing: [String]) -> [String] {
        let gone = Set(removing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var seen = Set<String>()
        var result: [String] = []
        for tag in have + adding {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !gone.contains(key), seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
