//
//  Schema+Fields.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension Schema {

    /// The field called `name`.
    func field(_ name: String) -> Field? { fields.first { $0.name == name } }

    /// The key field, when there is one.
    var keyField: Field? { key.flatMap(field) }
}

extension Schema {

    /// The column a link to this collection matches: the key, or `id`.
    var linkColumn: String { key ?? "id" }
}

public extension Field {

    /// Whether this field links to another collection.
    var isLink: Bool { type == .ref || type == .refs }

    /// Whether this field holds a list (tags or links), spread one value per
    /// row when grouped.
    var isList: Bool { type == .tags || type == .refs }
}
