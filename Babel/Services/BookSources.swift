import Foundation
import SwiftSoup

/// Woher der Bücher-Tab seine freien Bücher holt.
enum BookLibrary: String, CaseIterable, Identifiable, Sendable {
    case gutenberg, standardEbooks, archive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gutenberg: "Gutenberg"
        case .standardEbooks: "Standard Ebooks"
        case .archive: "Archive"
        }
    }

    var about: String {
        switch self {
        case .gutenberg: String(localized: "Über 75.000 freie Bücher, viele auf Deutsch.")
        case .standardEbooks: String(localized: "Rund 1.000 Klassiker, sorgfältig gesetzt und korrigiert – nur Englisch.")
        case .archive: String(localized: "Internet Archive: Zehntausende gemeinfreie Bücher als EPUB. Oft automatisch aus Scans erzeugt, Qualität schwankt.")
        }
    }

    /// Standard Ebooks hat weder Sprachen noch Themen-Suche.
    var supportsSubjects: Bool { self != .standardEbooks }
    var supportsLanguage: Bool { self != .standardEbooks }

    func search(_ filters: GutenbergFilters, page: Int) async throws -> GutenbergService.Page {
        switch self {
        case .gutenberg: try await GutenbergService.search(filters, page: page)
        case .standardEbooks: try await StandardEbooksService.search(filters, page: page)
        case .archive: try await ArchiveService.search(filters, page: page)
        }
    }
}

// MARK: - Standard Ebooks

/// standardebooks.org – liest die öffentliche Suchseite (die OPDS-Feeds sind nur für Förderer).
enum StandardEbooksService {
    static let base = URL(string: "https://standardebooks.org")!

    static func search(_ f: GutenbergFilters, page: Int) async throws -> GutenbergService.Page {
        var comps = URLComponents(url: base.appendingPathComponent("ebooks"), resolvingAgainstBaseURL: false)!
        let text = [f.query, f.title, f.author, f.subject].map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
        let sort = switch f.sort {
        case .downloads: "popularity"
        case .releaseDate: "newest"
        case .author: "author-alpha"
        case .title: "popularity"
        }
        comps.queryItems = [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "per-page", value: "24"),
        ]
        if page > 1 { comps.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        let (html, _, status) = try await HTTPClient.shared.html(comps.url!, minInterval: 0.4)
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            var books: [RemoteStory] = []
            for li in try doc.select("li[typeof=schema:Book]").array() {
                let path = try li.attr("about")
                guard path.hasPrefix("/ebooks/") else { continue }
                let title = try li.select("p span[property=schema:name]").first()?.text() ?? ""
                var s = RemoteStory(source: .standardEbooks, sourceID: path, title: title,
                                    url: base.appendingPathComponent(String(path.dropFirst())))
                s.author = try li.select("p.author span[property=schema:name]").array().map { try $0.text() }.joined(separator: ", ")
                if let img = try li.select("img").first() {
                    s.coverURL = URL(string: try img.attr("src"), relativeTo: base)?.absoluteURL
                }
                s.isComplete = true
                s.language = "English"
                s.downloadURL = epubURL(path: path)
                books.append(s)
            }
            let hasNext = try !doc.select("a[rel=next]").array().isEmpty
            return GutenbergService.Page(books: books, hasNext: hasNext)
        }.value
    }

    /// "/ebooks/franz-kafka/the-castle/willa-muir_edwin-muir"
    /// → ".../downloads/franz-kafka_the-castle_willa-muir-edwin-muir.epub"
    static func epubURL(path: String) -> URL {
        let parts = path.split(separator: "/").dropFirst().map { $0.replacingOccurrences(of: "_", with: "-") }
        // Ohne `source=download` zeigt Standard Ebooks erst eine Dankeseite (HTML) statt der Datei.
        let file = base.appendingPathComponent(String(path.dropFirst())).appendingPathComponent("downloads/\(parts.joined(separator: "_")).epub")
        return URL(string: file.absoluteString + "?source=download")!
    }

    static func details(path: String) async throws -> RemoteStory {
        let url = base.appendingPathComponent(String(path.dropFirst()))
        let (html, _, status) = try await HTTPClient.shared.html(url, minInterval: 0.4)
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            var s = RemoteStory(source: .standardEbooks, sourceID: path, title: "", url: url)
            s.summary = try doc.select("meta[name=description]").first()?.attr("content") ?? ""
            s.tags = try doc.select("ul.tags li a").array().map { try $0.text() }
            if let words = try doc.select("[property=schema:wordCount]").first()?.attr("content").digitsInt { s.words = words }
            if let epub = try doc.select("a[href$=.epub]").array()
                .first(where: { let h = (try? $0.attr("href")) ?? ""; return !h.contains("kepub") && !h.contains("advanced") }) {
                s.downloadURL = URL(string: try epub.attr("href") + "?source=download", relativeTo: base)?.absoluteURL
            }
            s.isComplete = true
            s.language = "English"
            return s
        }.value
    }
}

// MARK: - Internet Archive

/// archive.org – Volltextsuche über die Advanced-Search-API, nur frei zugängliche Texte mit EPUB.
enum ArchiveService {
    static let base = URL(string: "https://archive.org")!

    /// ISO-Kürzel → Sprachcode im Archive (MARC).
    private static let languageCodes: [String: String] = [
        "de": "ger", "en": "eng", "fr": "fre", "es": "spa", "it": "ita", "nl": "dut",
        "pt": "por", "fi": "fin", "sv": "swe", "la": "lat", "el": "gre",
    ]

    static func search(_ f: GutenbergFilters, page: Int) async throws -> GutenbergService.Page {
        func field(_ name: String, _ value: String) -> String? {
            let v = value.trimmed.replacingOccurrences(of: "\"", with: "")
            return v.isEmpty ? nil : "\(name):(\(v))"
        }
        // Nur Bücher: Zeitschriften, Zeitungen und Adressbücher machen sonst die Liste voll.
        var parts = ["mediatype:texts", "format:EPUB", "NOT access-restricted-item:true", "NOT collection:inlibrary",
                     "NOT collection:(magazine_rack OR periodicals OR newspapers OR pulpmagazinearchive OR microfilm)",
                     "NOT subject:(periodicals OR directories OR magazine)"]
        // Ohne Suchbegriff: Literatur statt beliebiger Scans.
        if f.query.trimmed.isEmpty && f.title.trimmed.isEmpty && f.author.trimmed.isEmpty && f.subject.trimmed.isEmpty {
            parts.append("subject:(fiction OR literature OR novel OR poetry OR drama)")
        }
        if !f.query.trimmed.isEmpty { parts.append("(\(f.query.trimmed))") }
        parts += [field("title", f.title), field("creator", f.author), field("subject", f.subject)].compactMap { $0 }
        if let code = languageCodes[f.language] { parts.append("language:(\(code))") }
        let sort = switch f.sort {
        case .downloads: "downloads desc"
        case .releaseDate: "publicdate desc"
        case .title: "titleSorter asc"
        case .author: "creatorSorter asc"
        }
        var comps = URLComponents(url: base.appendingPathComponent("advancedsearch.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: parts.joined(separator: " AND "))]
            + ["identifier", "title", "creator", "language", "downloads", "date", "subject"].map { URLQueryItem(name: "fl[]", value: $0) }
            + [URLQueryItem(name: "sort[]", value: sort), URLQueryItem(name: "rows", value: "25"),
               URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "output", value: "json")]

        let (data, http) = try await HTTPClient.shared.data(comps.url!, headers: ["Accept": "application/json"], minInterval: 0.4)
        guard http.statusCode == 200 else { throw BabelError.http(http.statusCode) }

        struct Response: Decodable {
            struct Inner: Decodable { let numFound: Int; let docs: [Doc] }
            let response: Inner
        }
        struct Doc: Decodable {
            let identifier: String
            let title: Flexible?
            let creator: Flexible?
            let language: Flexible?
            let subject: Flexible?
            let downloads: Int?
            let date: String?
        }
        let result = try JSONDecoder().decode(Response.self, from: data).response
        let books = result.docs.map { d -> RemoteStory in
            var s = RemoteStory(source: .archive, sourceID: d.identifier, title: d.title?.values.first ?? d.identifier,
                                url: base.appendingPathComponent("details/\(d.identifier)"))
            s.author = d.creator?.values.prefix(2).map(GutenbergService.displayName).joined(separator: ", ") ?? ""
            s.language = Self.isoLanguage(d.language?.values.first ?? "")
            s.tags = Array((d.subject?.values ?? []).prefix(8))
            s.hits = d.downloads
            s.published = d.date.flatMap { DateParsing.iso.date(from: String($0.prefix(10))) }
            s.isComplete = true
            s.coverURL = base.appendingPathComponent("services/img/\(d.identifier)")
            return s
        }
        return GutenbergService.Page(books: books, hasNext: page * 25 < result.numFound)
    }

    /// "ger" → "de" usw., damit die Listen „DE“ statt „GER“ zeigen.
    static func isoLanguage(_ code: String) -> String {
        languageCodes.first { $0.value == code.lowercased() }?.key.uppercased() ?? code
    }

    /// Das EPUB eines Eintrags (Dateiname aus den Metadaten).
    static func epubURL(id: String) async throws -> URL {
        let files = try await metadata(id: id).files ?? []
        guard let epub = files.first(where: { $0.name.hasSuffix(".epub") && !$0.name.contains("_encrypted") }) else {
            throw BabelError.epub(String(localized: "Für diesen Eintrag gibt es kein freies EPUB."))
        }
        let path = epub.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? epub.name
        return URL(string: "https://archive.org/download/\(id)/\(path)")!
    }

    static func details(id: String) async throws -> RemoteStory {
        let meta = try await metadata(id: id)
        var s = RemoteStory(source: .archive, sourceID: id, title: meta.metadata?.title?.values.first ?? id,
                            url: base.appendingPathComponent("details/\(id)"))
        s.summary = (meta.metadata?.description?.values.joined(separator: "\n\n") ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmed
        s.tags = Array((meta.metadata?.subject?.values ?? []).prefix(10))
        s.isComplete = true
        return s
    }

    private struct Metadata: Decodable {
        struct File: Decodable { let name: String }
        struct Info: Decodable {
            let title: Flexible?
            let description: Flexible?
            let subject: Flexible?
        }
        let files: [File]?
        let metadata: Info?
    }

    private static func metadata(id: String) async throws -> Metadata {
        let (data, http) = try await HTTPClient.shared.data(base.appendingPathComponent("metadata/\(id)"),
                                                            headers: ["Accept": "application/json"], minInterval: 0.4)
        guard http.statusCode == 200 else { throw BabelError.http(http.statusCode) }
        return try JSONDecoder().decode(Metadata.self, from: data)
    }

    /// Das Archive liefert Felder mal als Text, mal als Liste.
    struct Flexible: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { values = [s] }
            else { values = (try? c.decode([String].self)) ?? [] }
        }
    }
}
