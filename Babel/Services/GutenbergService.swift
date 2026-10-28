import Foundation
import SwiftSoup

enum GutenbergSort: String, Codable, CaseIterable, Sendable, Hashable {
    case downloads, releaseDate = "release_date", title, author

    var label: String {
        switch self {
        case .downloads: String(localized: "Beliebtheit")
        case .releaseDate: String(localized: "Neu bei Gutenberg")
        case .title: String(localized: "Titel")
        case .author: String(localized: "Autor:in")
        }
    }
}

/// Worin das Suchfeld sucht.
enum GutenbergScope: String, Codable, CaseIterable, Sendable, Hashable {
    case all, title, author, subject

    var label: String {
        switch self { case .all: String(localized: "Alles"); case .title: String(localized: "Titel"); case .author: String(localized: "Autor:in"); case .subject: String(localized: "Thema") }
    }

    var prefix: String? {
        switch self { case .all: nil; case .title: "t"; case .author: "a"; case .subject: "s" }
    }
}

/// Filter der Gutenberg-Suche (entspricht der Präfix-Syntax von gutenberg.org: a. t. s. l.).
struct GutenbergFilters: Codable, Hashable, Sendable {
    var query = ""
    var scope: GutenbergScope = .all
    var title = ""
    var author = ""
    var subject = ""
    var language = "de"
    var sort: GutenbergSort = .downloads

    init() {}

    // Eigener Decoder, damit alte gespeicherte Filter (ohne `scope`) weiter laden.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        scope = try c.decodeIfPresent(GutenbergScope.self, forKey: .scope) ?? .all
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "de"
        sort = try c.decodeIfPresent(GutenbergSort.self, forKey: .sort) ?? .downloads
    }

    var activeCount: Int {
        [title, author, subject].filter { !$0.trimmed.isEmpty }.count
    }

    var queryString: String {
        func prefixed(_ prefix: String, _ text: String) -> [String] {
            text.trimmed.split(whereSeparator: \.isWhitespace).map { "\(prefix).\($0)" }
        }
        var parts = scope.prefix.map { prefixed($0, query) } ?? query.trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        parts += prefixed("t", title)
        parts += prefixed("a", author)
        parts += prefixed("s", subject)
        if !language.isEmpty { parts.append("l.\(language)") }
        return parts.joined(separator: " ")
    }
}

/// Freie Bücher direkt von gutenberg.org (die Gutendex-API braucht oft über eine Minute).
enum GutenbergService {
    static let base = URL(string: "https://www.gutenberg.org")!

    static let languages: [LanguageOption] = [
        .init(code: "", name: String(localized: "Alle Sprachen")), .init(code: "de", name: String(localized: "Deutsch")), .init(code: "en", name: String(localized: "English")),
        .init(code: "fr", name: "Français"), .init(code: "es", name: "Español"), .init(code: "it", name: "Italiano"),
        .init(code: "nl", name: "Nederlands"), .init(code: "pt", name: "Português"), .init(code: "fi", name: "Suomi"),
        .init(code: "sv", name: "Svenska"), .init(code: "la", name: "Latina"), .init(code: "el", name: "Ελληνικά"),
    ]

    /// Beliebte Themen als Schnellstart.
    static let subjects: [(label: String, query: String)] = [
        (String(localized: "Romane"), "fiction"), (String(localized: "Abenteuer"), "adventure"), (String(localized: "Krimis"), "detective"), (String(localized: "Science-Fiction"), "science fiction"),
        (String(localized: "Fantasy"), "fantasy"), (String(localized: "Liebe"), "love stories"), (String(localized: "Märchen"), "fairy tales"), (String(localized: "Lyrik"), "poetry"),
        (String(localized: "Drama"), "drama"), (String(localized: "Philosophie"), "philosophy"), (String(localized: "Geschichte"), "history"), (String(localized: "Kinderbücher"), "juvenile"),
    ]

    struct Page: Sendable {
        var books: [RemoteStory]
        var hasNext: Bool
    }

    static let pageSize = 25

    static func searchURL(_ f: GutenbergFilters, page: Int) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("ebooks/search/"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "query", value: f.queryString), URLQueryItem(name: "sort_order", value: f.sort.rawValue)]
        if page > 1 { items.append(URLQueryItem(name: "start_index", value: String((page - 1) * pageSize + 1))) }
        comps.queryItems = items
        return comps.url!
    }

    static func search(_ filters: GutenbergFilters, page: Int) async throws -> Page {
        let (html, _, status) = try await HTTPClient.shared.html(searchURL(filters, page: page), minInterval: 0.3)
        guard status == 200 else { throw BabelError.http(status) }
        let language = filters.language
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            var books: [RemoteStory] = []
            for li in try doc.select("li.booklink").array() {
                guard let a = try li.select("a.link").first(),
                      let id = try a.attr("href").firstMatch(#"/ebooks/(\d+)"#)?[1] else { continue }
                var s = RemoteStory(source: .gutenberg, sourceID: id,
                                    title: cleanTitle(try li.select("span.title").first()?.text() ?? String(localized: "Ohne Titel")),
                                    url: base.appendingPathComponent("ebooks/\(id)"))
                s.author = try li.select("span.subtitle").first()?.text() ?? ""
                s.hits = try li.select("span.extra").first()?.text().firstMatch(#"(\d+)"#)?[1].digitsInt
                s.isComplete = true
                s.language = language
                s.coverURL = coverURL(id)
                s.downloadURL = epubURL(id)
                books.append(s)
            }
            let hasNext = try !doc.select("a[accesskey=\"+\"], a[title=\"Go to the next page of results.\"]").array().isEmpty
            return Page(books: books, hasNext: hasNext)
        }.value
    }

    static func coverURL(_ id: String) -> URL { base.appendingPathComponent("cache/epub/\(id)/pg\(id).cover.medium.jpg") }
    static func epubURL(_ id: String) -> URL { base.appendingPathComponent("ebooks/\(id).epub3.images") }

    /// Details von der Buchseite: Zusammenfassung, Themen, Sprache, Veröffentlichung.
    static func details(id: String) async throws -> RemoteStory {
        let (html, _, status) = try await HTTPClient.shared.html(base.appendingPathComponent("ebooks/\(id)"), minInterval: 0.3)
        if status == 404 { throw BabelError.notFound }
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            var s = RemoteStory(source: .gutenberg, sourceID: id, title: "", url: base.appendingPathComponent("ebooks/\(id)"))
            s.title = try doc.select("td[itemprop=headline]").first()?.text() ?? ""
            s.author = try doc.select("a[rel=marcrel:aut]").array().map { displayName(try $0.text()) }.joined(separator: ", ")
            s.tags = try doc.select("td[property=dcterms:subject] a").array().map { try $0.text() }
            s.language = try doc.select("tr[property=dcterms:language]").first()?.attr("content") ?? ""
            for row in try doc.select("table.bibrec tr").array() {
                let key = try row.select("th").first()?.text() ?? ""
                let value = try row.select("td").first()?.text() ?? ""
                switch key {
                case "Summary": s.summary = value.replacingOccurrences(of: "(This is an automatically generated summary.)", with: "").trimmed
                case "Downloads": s.hits = value.firstMatch(#"(\d+)"#)?[1].digitsInt
                case "Release Date":
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "MMM d, yyyy"
                    s.published = f.date(from: value)
                case "Category": s.categories = [value]
                default: break
                }
            }
            if s.summary.isEmpty, let box = try doc.select("div.summary-text-container").first() {
                try box.select("label").remove()
                s.summary = try box.text()
                    .replacingOccurrences(of: "(This is an automatically generated summary.)", with: "")
                    .trimmed
            }
            s.isComplete = true
            s.coverURL = coverURL(id)
            s.downloadURL = epubURL(id)
            return s
        }.value
    }

    /// "Faust (German)" → "Faust" – die Sprache steht ohnehin in den Metadaten.
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*\((German|English|French|Spanish|Italian|Dutch|Portuguese|Finnish|Swedish|Latin|Greek|Danish|Norwegian|Polish|Russian|Hungarian|Czech)\)$"#,
            with: "", options: .regularExpression)
    }

    /// "Goethe, Johann Wolfgang von, 1749-1832" → "Johann Wolfgang von Goethe"
    static func displayName(_ name: String) -> String {
        var parts = name.components(separatedBy: ", ")
        if let last = parts.last, last.first?.isNumber == true || last.hasPrefix("-") { parts.removeLast() }
        guard parts.count == 2 else { return parts.joined(separator: ", ") }
        return "\(parts[1]) \(parts[0])"
    }
}
