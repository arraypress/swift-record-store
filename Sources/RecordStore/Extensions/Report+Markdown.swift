//
//  Report+Markdown.swift
//  RecordStore
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension Report {

    /// The report as Markdown. With `frontMatter` (the default) the title,
    /// period and date go in a YAML block that `press` sets as the title
    /// block; without it, as a heading and a line.
    func markdown(frontMatter: Bool = true) -> String {
        ReportMarkdown.render(self, frontMatter: frontMatter)
    }
}
