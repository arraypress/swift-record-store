//
//  RecordStoreError+Description.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

extension RecordStoreError: LocalizedError {

    public var errorDescription: String? { message }

    /// One sentence a person or an agent can act on.
    public var message: String {
        switch self {
        case .invalidSchema(let reason): return "invalid schema: \(reason)"
        case .unknownCollection(let name): return "no collection called \"\(name)\""
        case .unknownField(let collection, let field): return "\(collection) has no field \"\(field)\""
        case .invalidValue(let field, let reason): return field.isEmpty ? reason : "\(field): \(reason)"
        case .invalidRecords(let problems): return "nothing was stored — \(problems.count) record\(problems.count == 1 ? "" : "s") did not fit:\n  " + problems.joined(separator: "\n  ")
        case .invalidQuery(let reason): return reason
        case .unreadableJSON(let reason): return "not JSON: \(reason)"
        case .duplicate(let reason): return "duplicate: \(reason)"
        case .recordNotFound(let collection, let id): return "\(collection) has no record #\(id)"
        case .keyNotFound(let collection, let key): return "\(collection) has no record \"\(key)\""
        case .linked(let reason): return reason
        case .cannotUndo(let reason): return "cannot undo: \(reason)"
        case .readOnly(let reason): return reason
        case .storage(let reason): return "storage failed: \(reason)"
        }
    }
}
