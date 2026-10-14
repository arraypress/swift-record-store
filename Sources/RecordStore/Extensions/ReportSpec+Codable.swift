//
//  ReportSpec+Codable.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  Saved report specs are written by people as often as by code: lists may
//  be left out, filters written as text and windows as words.
//

import Foundation

extension ReportSpec {

    /// Lists left out of a saved spec are empty; filters may be written as
    /// text (`"severity > 2"`) as well as objects.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        filters = try Filter.decodeList(c, .filters)
        since = try c.decodeIfPresent(String.self, forKey: .since)
        until = try c.decodeIfPresent(String.self, forKey: .until)
        last = try c.decodeIfPresent(String.self, forKey: .last)
        dateField = try c.decodeIfPresent(String.self, forKey: .dateField)
        every = try c.decodeIfPresent(Grouping.Period.self, forKey: .every)
        averages = try c.decodeIfPresent([String].self, forKey: .averages) ?? []
        sums = try c.decodeIfPresent([String].self, forKey: .sums) ?? []
        top = try c.decodeIfPresent([String].self, forKey: .top) ?? []
        topLimit = try c.decodeIfPresent(Int.self, forKey: .topLimit)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        window = try c.decodeIfPresent(ReportWindow.self, forKey: .window)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

extension ReportSpec.ReportWindow {

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposures = try c.decode(String.self, forKey: .exposures)
        exposureFilters = try Filter.decodeList(c, .exposureFilters)
        exposureDateField = try c.decodeIfPresent(String.self, forKey: .exposureDateField)
        // "30m..3h" or "symptom.onset_hours" as well as the coded form.
        if let text = try? c.decode(String.self, forKey: .within) {
            within = try WindowSpec.Window.parse(text)
        } else {
            within = try c.decode(WindowSpec.Window.self, forKey: .within)
        }
        tally = try c.decodeIfPresent([String].self, forKey: .tally) ?? []
        minEvents = try c.decodeIfPresent(Int.self, forKey: .minEvents) ?? 2
    }
}

extension Filter {

    /// Filters as objects or as `field op value` text.
    static func decodeList<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> [Filter] {
        if let texts = try? c.decode([String].self, forKey: key) {
            return try texts.map { (text: String) throws -> Filter in try FilterParsing.parse(text) }
        }
        return try c.decodeIfPresent([Filter].self, forKey: key) ?? []
    }
}
