import Foundation
import CryptoKit
import SwiftSoup

/// Ein OPDS-Katalog: der offene Standard, über den Bibliotheken, Verlage und eigene Server
/// (Calibre-Web, Kavita, Komga …) ihre Bücher anbieten.
struct OPDSCatalog: Codable, Hashable, Identifiable, Sendable {
    var title: String
    var url: URL
    var about: String = ""
    var id: String { url.absoluteString }

    /// Geprüfte, frei zugängliche Kataloge als Vorschlag.
    static let suggestions: [OPDSCatalog] = [
        OPDSCatalog(title: "Unglue.it", url: URL(string: "https://unglue.it/api/opds/")!,
                    about: String(localized: "Neuere Bücher unter freier Lizenz (Creative Commons), dazu frei zugängliche Sach- und Fachbücher.")),
        OPDSCatalog(title: "Ebooks libres et gratuits", url: URL(string: "https://www.ebooksgratuits.com/opds/")!,
                    about: String(localized: "Französische Klassiker, sorgfältig aufbereitet.")),
        OPDSCatalog(title: "Wolne Lektury", url: URL(string: "https://wolnelektury.pl/opds/")!,
                    about: String(localized: "Polnische Literatur, frei zugänglich.")),
    ]
}

/// Die Kataloge des Nutzers (über iCloud synchronisiert, siehe `SettingsSync.keys`).
enum OPDSCatalogStore {
    static let key = "books.catalogs"

    static func decode(_ data: Data) -> [OPDSCatalog] {
        // Noch nie etwas gespeichert: mit Unglue.it starten.
        guard !data.isEmpty else { return [OPDSCatalog.suggestions[0]] }
        return (try? JSONDecoder().decode([OPDSCatalog].self, from: data)) ?? []
    }

    static func encode(_ catalogs: [OPDSCatalog]) -> Data {
        (try? JSONEncoder().encode(catalogs)) ?? Data()
    }
}

struct OPDSFeed: Sendable {
    enum Entry: Identifiable, Sendable {
        case book(RemoteStory)
        case navigation(title: String, subtitle: String, url: URL)

        var id: String {
            switch self {
            case .book(let story): story.id
            case .navigation(_, _, let url): url.absoluteString
            }
        }
    }

    var title: String
    var entries: [Entry]
    var next: URL?
    /// Suchvorlage mit `{searchTerms}`, falls der Katalog eine Suche anbietet.
    var searchTemplate: String?
    /// Verweis auf eine OpenSearch-Beschreibung – die Vorlage steht erst dort.
    var searchDescription: URL?
    /// „Beliebt“/„Empfohlen“/„Neu“, falls der Katalog so etwas ausweist (für die Vorschau im Bücher-Tab).
    var featured: URL?
    /// Einträge ohne EPUB (nur PDF o. Ä.) – Babel liest nur EPUB.
    var hiddenCount = 0

    var books: [RemoteStory] {
        entries.compactMap { if case .book(let story) = $0 { story } else { nil } }
    }
}

enum OPDSService {
    static func feed(_ url: URL) async throws -> OPDSFeed {
        let (data, http) = try await HTTPClient.shared.data(
            url, headers: ["Accept": "application/atom+xml,application/xml;q=0.9,*/*;q=0.5"], minInterval: 0.3)
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw BabelError.unsupported(String(localized: "Dieser Katalog verlangt eine Anmeldung – das kann Babel noch nicht.")) }
            throw BabelError.http(http.statusCode)
        }
        let xml = String(decoding: data, as: UTF8.self)
        let final = http.url ?? url
        return try await Task.detached(priority: .userInitiated) { try parse(xml, url: final) }.value
    }

    /// Ein paar Bücher zum Vorzeigen: der Katalog selbst, sonst sein „Beliebt“-Verweis, sonst der erste Unterkatalog mit Büchern.
    static func showcase(_ catalog: OPDSCatalog) async throws -> [RemoteStory] {
        var feed = try await feed(catalog.url)
        var hops = 0
        while feed.books.isEmpty, hops < 2 {
            let nextURL: URL? = feed.featured ?? feed.entries.lazy.compactMap { if case .navigation(_, _, let url) = $0 { url } else { nil } }.first
            guard let nextURL else { break }
            feed = try await self.feed(nextURL)
            hops += 1
        }
        // Viele Kataloge führen auch PDFs: ein, zwei Seiten weiterblättern, bis die Reihe gefüllt ist.
        var books = feed.books
        var pages = 0
        while books.count < 8, pages < 2, let next = feed.next {
            feed = try await self.feed(next)
            let known = Set(books.map(\.id))
            books += feed.books.filter { !known.contains($0.id) }
            pages += 1
        }
        return books
    }

    static func searchURL(_ feed: OPDSFeed, query: String) async throws -> URL? {
        var template = feed.searchTemplate
        if template == nil, let description = feed.searchDescription {
            let (data, http) = try await HTTPClient.shared.data(description, minInterval: 0.3)
            guard http.statusCode == 200 else { return nil }
            let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self), description.absoluteString, Parser.xmlParser())
            let urls = try doc.select("Url").array()
            let atom = try urls.first { try $0.attr("type").contains("atom") } ?? urls.first
            template = try atom.map { absolute(try $0.attr("template"), against: description) }
        }
        guard var template, template.contains("{searchTerms}") else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
        template = template.replacingOccurrences(of: "{searchTerms}", with: query.trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        template = template.replacingOccurrences(of: "{startPage?}", with: "1")
        // Übrige freiwillige Parameter leer lassen.
        template = template.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        return URL(string: template)
    }

    /// Suchvorlage absolut machen. Als Text: Die geschweiften Klammern überleben `URL` nicht.
    private static func absolute(_ template: String, against url: URL) -> String {
        if template.hasPrefix("http") { return template }
        var origin = "\(url.scheme ?? "https")://\(url.host ?? "")"
        if let port = url.port { origin += ":\(port)" }
        return origin + (template.hasPrefix("/") ? template : "/" + template)
    }

    // MARK: Auswerten

    static func parse(_ xml: String, url: URL) throws -> OPDSFeed {
        let doc = try SwiftSoup.parse(xml, url.absoluteString, Parser.xmlParser())
        guard let root = try doc.select("feed").first() else {
            throw BabelError.unsupported(String(localized: "Das ist kein OPDS-Katalog (OPDS 1.x, Atom)."))
        }
        func resolve(_ href: String) -> URL? {
            guard !href.isEmpty, !href.hasPrefix("data:") else { return nil }
            return URL(string: href, relativeTo: url)?.absoluteURL
                ?? URL(string: href.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? href, relativeTo: url)?.absoluteURL
        }
        func child(_ parent: Element, _ names: String...) -> Element? {
            parent.children().array().first { names.contains($0.tagName().lowercased()) }
        }
        func text(_ parent: Element, _ names: String...) -> String {
            let element = parent.children().array().first { names.contains($0.tagName().lowercased()) }
            return ((try? element?.text()) ?? "").trimmed
        }

        var feed = OPDSFeed(title: text(root, "title"), entries: [])
        var featured: [String: URL] = [:]
        for link in root.children().array() where link.tagName().lowercased() == "link" {
            let rel = try link.attr("rel"), type = try link.attr("type"), href = try link.attr("href")
            switch rel {
            case "next": feed.next = resolve(href)
            case "search":
                if type.contains("opensearchdescription") { feed.searchDescription = resolve(href) }
                else if href.contains("{searchTerms}") {
                    feed.searchTemplate = absolute(href, against: url)
                }
            default:
                if rel.contains("featured") || rel.contains("sort/popular") || rel.contains("sort/new") { featured[rel] = resolve(href) }
            }
        }

        var seen: Set<String> = []
        for entry in root.children().array() where entry.tagName().lowercased() == "entry" {
            let title = text(entry, "title")
            let links = entry.children().array().filter { $0.tagName().lowercased() == "link" }
            var download: URL?, cover: URL?, thumbnail: URL?, page: URL?, navigation: URL?
            var hasAcquisition = false
            for link in links {
                let rel = try link.attr("rel"), type = try link.attr("type").lowercased(), href = try link.attr("href")
                if rel == "http://opds-spec.org/acquisition" || rel == "http://opds-spec.org/acquisition/open-access" {
                    hasAcquisition = true
                    if type.contains("epub"), download == nil { download = resolve(href) }
                } else if rel.hasPrefix("http://opds-spec.org/acquisition") {
                    hasAcquisition = true
                } else if rel == "http://opds-spec.org/image" || rel == "http://opds-spec.org/cover" {
                    cover = resolve(href)
                } else if rel.contains("thumbnail") {
                    thumbnail = resolve(href)
                } else if rel == "alternate", type.contains("html") {
                    page = resolve(href)
                } else if type.contains("atom+xml"), navigation == nil, rel != "related", rel != "self" {
                    navigation = resolve(href)
                    if rel.contains("sort/popular") || rel.contains("featured") || rel.contains("sort/new"), let navigation { featured[rel] = featured[rel] ?? navigation }
                }
            }

            if let download {
                let rawID = text(entry, "id").isEmpty ? download.absoluteString : text(entry, "id")
                let id = SHA256.hash(data: Data(rawID.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
                guard seen.insert(id).inserted else { continue }
                var story = RemoteStory(source: .opds, sourceID: id, title: title.isEmpty ? String(localized: "Ohne Titel") : title, url: page ?? download)
                story.author = entry.children().array().filter { $0.tagName().lowercased() == "author" }
                    .map { text($0, "name") }.filter { !$0.isEmpty }.joined(separator: ", ")
                let summary = text(entry, "summary").isEmpty ? text(entry, "content") : text(entry, "summary")
                story.summary = summary.contains("<") ? ((try? SwiftSoup.parse(summary).text()) ?? summary) : summary
                story.language = text(entry, "dcterms:language", "dc:language").uppercased()
                story.tags = Array(entry.children().array().filter { $0.tagName().lowercased() == "category" }
                    .compactMap { c -> String? in
                        let label = (try? c.attr("label")) ?? ""
                        let term = (try? c.attr("term")) ?? ""
                        return label.isEmpty ? (term.isEmpty ? nil : term) : label
                    }.prefix(12))
                let issued = text(entry, "dcterms:issued", "dc:date", "published")
                if let year = issued.firstMatch(#"(\d{4})"#)?[1] { story.published = DateParsing.iso.date(from: "\(year)-01-01") }
                story.coverURL = cover ?? thumbnail
                story.downloadURL = download
                story.isComplete = true
                feed.entries.append(.book(story))
            } else if hasAcquisition {
                feed.hiddenCount += 1
            } else if let navigation {
                let subtitle = text(entry, "content").isEmpty ? text(entry, "summary") : text(entry, "content")
                feed.entries.append(.navigation(title: title, subtitle: subtitle, url: navigation))
            }
        }
        feed.featured = featured.first { $0.key.contains("featured") }?.value
            ?? featured.first { $0.key.contains("popular") }?.value ?? featured.values.first
        return feed
    }
}
