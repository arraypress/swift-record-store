//
//  ReportMarkdown.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//
//  A Report as Markdown: front matter (title, subtitle, date — what `press`
//  sets as the title block), the notes, then each section as a heading, a
//  sentence and a GFM table. Cells are escaped so a `|` in a meal's name
//  cannot break a row.
//

import Foundation

enum ReportMarkdown {

    static func render(_ report: Report, frontMatter: Bool) -> String {
        var out: [String] = []
        let subtitle = subtitle(report)
        if frontMatter {
            out.append("---")
            out.append("title: \(quoted(report.title))")
            out.append("subtitle: \(quoted(subtitle))")
            out.append("date: \(quoted(String(report.generatedAt.prefix(10))))")
            out.append("---")
            out.append("")
        } else {
            out.append("# \(report.title)")
            out.append("")
            out.append("*\(subtitle)*")
            out.append("")
        }
        if let notes = report.notes, !notes.isEmpty {
            out.append(notes)
            out.append("")
        }
        for section in report.sections {
            out.append("## \(section.title)")
            out.append("")
            if let note = section.note {
                out.append(note)
                out.append("")
            }
            guard !section.table.rows.isEmpty else { continue }
            out.append(table(section))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func subtitle(_ report: Report) -> String {
        let records = "\(report.count) record\(report.count == 1 ? "" : "s")"
        switch (report.from, report.to) {
        case (let from?, let to?) where from == to: return "\(readable(from)) · \(records)"
        case (let from?, let to?): return "\(readable(from)) to \(readable(to)) · \(records)"
        case (let from?, nil): return "From \(readable(from)) · \(records)"
        case (nil, let to?): return "Up to \(readable(to)) · \(records)"
        default: return records
        }
    }

    /// `2026-10-14` → `14 Oct 2026`.
    static func readable(_ day: String) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(parts[2]) \(months[parts[1] - 1]) \(parts[0])"
    }

    static func heading(_ column: String) -> String {
        if column == "count" { return "records" }
        for (suffix, word) in [("_avg", "average"), ("_sum", "total"), ("_min", "lowest"), ("_max", "highest"), ("_running", "running total")]
        where column.hasSuffix(suffix) {
            return "\(word) \(column.dropLast(suffix.count).replacingOccurrences(of: "_", with: " "))"
        }
        return column.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " → ")
    }

    static func table(_ section: Section) -> String {
        let columns = section.table.columns
        // Right-aligned when every value is a number, a share or money
        // (and at least one is there).
        let numeric = columns.map { column in
            let values = section.table.rows.map { $0[column] ?? .null }.filter { $0 != .null }
            return !values.isEmpty && values.allSatisfy { value in
                switch value {
                case .number: return true
                case .string(let s): return s.hasSuffix("%")
                case .object(let o): return o["amount"] != nil
                default: return false
                }
            }
        }
        var lines = ["| " + columns.map { cell(section.headings[$0] ?? heading($0)) }.joined(separator: " | ") + " |"]
        lines.append("|" + numeric.map { $0 ? " --: |" : " --- |" }.joined())
        for row in section.table.rows {
            lines.append("| " + columns.map { cell(display(row[$0] ?? .null)) }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    typealias Section = Report.Section

    /// A value for a reader: averages to two places, the rest as stored.
    static func display(_ value: JSONValue) -> String {
        if case .number(let n) = value { return ValueDisplay.text(.number(DecimalMath.rounded(n, places: 2))) }
        return ValueDisplay.text(value)
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
