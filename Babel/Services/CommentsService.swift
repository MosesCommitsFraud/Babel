import Foundation
import SwiftSoup

/// Ein Review (FFN) bzw. Kommentar (AO3).
struct StoryComment: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var chapter: Int?
    var date: Date?
    var text: String
    /// Antwort auf einen anderen Kommentar (nur AO3).
    var isReply = false
}

struct CommentsPage: Sendable {
    var comments: [StoryComment]
    var hasNext: Bool
}

enum CommentsService {
    static func load(source: StorySource, storyID: String, page: Int) async throws -> CommentsPage {
        switch source {
        case .ffn: try await ffnReviews(storyID: storyID, page: page)
        case .ao3: try await ao3Comments(workID: storyID, page: page)
        default: CommentsPage(comments: [], hasNext: false)
        }
    }

    // MARK: FanFiction.net – /r/<id>/0/<seite>/

    static func ffnReviews(storyID: String, page: Int) async throws -> CommentsPage {
        let url = FFNService.base.appendingPathComponent("r/\(storyID)/0/\(page)/")
        let (html, _) = try await FFNService.load(url, minInterval: 0.8)
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, FFNService.base.absoluteString)
            var result: [StoryComment] = []
            for (i, td) in try doc.select("#gui_table1 tbody tr > td, table.table-striped tbody tr > td").array().enumerated() {
                guard let textDiv = try td.select("div").last() else { continue }
                let text = try paragraphs(textDiv)
                guard !text.isEmpty else { continue }
                let small = try td.select("small").first()
                let chapter = try small?.text().firstMatch(#"chapter\s+(\d+)"#)?[1].digitsInt
                let date = try small?.select("span[data-xutime]").first().flatMap { Double(try $0.attr("data-xutime")) }
                    .map { Date(timeIntervalSince1970: $0) }
                var author = try td.select("a[href^=\"/u/\"]").first()?.text() ?? ""
                if author.isEmpty {
                    // Gäste: Name steht als Text vor <small>.
                    let copy = try SwiftSoup.parseBodyFragment(try td.html()).body()!
                    try copy.select("span, small, div, img, a").remove()
                    author = try copy.text().trimmed
                }
                result.append(StoryComment(id: "\(page)-\(i)", author: author.isEmpty ? String(localized: "Gast") : author,
                                           chapter: chapter, date: date, text: text))
            }
            let hasNext = try doc.select("a").array().contains { (try? $0.text().contains("Next")) ?? false }
            return CommentsPage(comments: result, hasNext: hasNext)
        }.value
    }

    // MARK: AO3 – /works/<id>?show_comments=true&page=<seite>

    static func ao3Comments(workID: String, page: Int) async throws -> CommentsPage {
        var comps = URLComponents(url: AO3Service.base.appendingPathComponent("works/\(workID)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "show_comments", value: "true"), URLQueryItem(name: "view_adult", value: "true")]
        if page > 1 { comps.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        let (html, _, status) = try await AO3Service.fetchHTML(comps.url!)
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, AO3Service.base.absoluteString)
            let dateFormat = DateFormatter()
            dateFormat.locale = Locale(identifier: "en_US_POSIX")
            dateFormat.dateFormat = "d MMM yyyy"
            var result: [StoryComment] = []
            for li in try doc.select("#comments_placeholder li.comment").array() {
                guard let body = try li.select("> blockquote.userstuff, blockquote.userstuff").first() else { continue }
                let byline = try li.select("h4.heading.byline").first()
                let author = try byline?.select("a").first()?.text() ?? byline?.ownText().trimmed ?? ""
                let chapter = try byline?.select("span.parent").first()?.text().firstMatch(#"Chapter\s+(\d+)"#)?[1].digitsInt
                var date: Date?
                if let posted = try li.select("span.posted.datetime").first() {
                    let parts = try ["span.date", "abbr.month", "span.month", "span.year"].compactMap { try posted.select($0).first()?.text() }
                    date = dateFormat.date(from: parts.joined(separator: " "))
                }
                // Antworten stecken in einem verschachtelten <ol class="thread"> innerhalb eines Kommentars.
                let isReply = li.parents().array().contains { $0.tagName() == "li" && $0.hasClass("comment") }
                result.append(StoryComment(id: li.id().isEmpty ? UUID().uuidString : li.id(),
                                           author: author.isEmpty ? String(localized: "Gast") : author,
                                           chapter: chapter, date: date, text: try paragraphs(body), isReply: isReply))
            }
            let hasNext = try !doc.select("#comments_placeholder ol.pagination li.next a").array().isEmpty
            return CommentsPage(comments: result, hasNext: hasNext)
        }.value
    }

    /// Absätze aus <p>/<br> erhalten, mehrere Leerzeilen zu einer zusammenfassen.
    private static func paragraphs(_ el: Element) throws -> String {
        try el.select("br").after("\n")
        let ps = try el.select("p").array()
        let raw = ps.isEmpty
            ? try el.text(trimAndNormaliseWhitespace: false)
            : try ps.map { try $0.text(trimAndNormaliseWhitespace: false) }.joined(separator: "\n\n")
        return raw.components(separatedBy: "\n")
            .map(\.trimmed)
            .split(separator: "", omittingEmptySubsequences: true)
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }
}
