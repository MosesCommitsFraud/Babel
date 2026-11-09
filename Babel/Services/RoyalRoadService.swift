import Foundation
import SwiftSoup

/// Royal Road (royalroad.com): Web-Serien und Web Novels, meist eigene Welten statt Fanfiction.
/// Es gibt keine offizielle API – gelesen werden die öffentlichen Seiten, wie im Browser.
enum RoyalRoadService {
    static let base = URL(string: "https://www.royalroad.com")!

    /// Die Listen der Website.
    enum List: String, CaseIterable, Identifiable, Sendable {
        case trending, bestRated = "best-rated", weekly = "weekly-popular", ongoing = "active-popular"
        case updates = "latest-updates", complete, rising = "rising-stars", new
        var id: String { rawValue }

        var label: String {
            switch self {
            case .trending: String(localized: "Im Trend")
            case .bestRated: String(localized: "Am besten bewertet")
            case .weekly: String(localized: "Beliebt diese Woche")
            case .ongoing: String(localized: "Beliebt & laufend")
            case .updates: String(localized: "Frisch aktualisiert")
            case .complete: String(localized: "Abgeschlossen")
            case .rising: String(localized: "Aufsteiger")
            case .new: String(localized: "Neu")
            }
        }
    }

    struct Page: Sendable {
        var stories: [RemoteStory]
        var hasNext: Bool
    }

    struct Fiction: Sendable {
        var meta: RemoteStory
        var titles: [String]
        /// Pfad je Kapitel ("/fiction/21220/…/chapter/301778/…") – landet in `Story.spinePaths`.
        var paths: [String]
    }

    static func listURL(_ list: List, page: Int) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("fictions/\(list.rawValue)"), resolvingAgainstBaseURL: false)!
        if page > 1 { comps.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        return comps.url!
    }

    static func searchURL(_ query: String, page: Int) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("fictions/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "title", value: query.trimmed)]
        if page > 1 { comps.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        return comps.url!
    }

    static func fictionURL(_ id: String) -> URL { base.appendingPathComponent("fiction/\(id)") }

    // MARK: Laden

    /// Erst direkt; sperrt Cloudflare das (403/503 mit Prüfseite), über den WebView wie bei FanFiction.net.
    static func load(_ url: URL) async throws -> String {
        if let (html, _, status) = try? await HTTPClient.shared.html(url, minInterval: 0.8), status == 200, !isChallenge(html) {
            return html
        }
        let page = try await WebFetcher.shared.load(url)
        if let code = SiteStatus.errorPageCode(page.html) {
            throw BabelError.siteDown(site: "Royal Road", reason: SiteStatus.reason(status: code))
        }
        return page.html
    }

    private static func isChallenge(_ html: String) -> Bool {
        html.contains("cf-challenge") || html.contains("challenge-platform") || html.contains("<title>Just a moment")
    }

    static func list(_ list: List, page: Int) async throws -> Page {
        let html = try await load(listURL(list, page: page))
        return try await Task.detached(priority: .userInitiated) { try parseList(html) }.value
    }

    static func search(_ query: String, page: Int) async throws -> Page {
        let html = try await load(searchURL(query, page: page))
        return try await Task.detached(priority: .userInitiated) { try parseList(html) }.value
    }

    static func fiction(id: String) async throws -> Fiction {
        let html = try await load(fictionURL(id))
        if html.contains("fiction-not-found") || html.contains("<title>Not Found") { throw BabelError.notFound }
        return try await Task.detached(priority: .userInitiated) { try parseFiction(html, id: id) }.value
    }

    static func chapter(path: String, fallbackTitle: String) async throws -> ChapterContent {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw BabelError.notFound }
        let html = try await load(url)
        return try await Task.detached(priority: .userInitiated) { try parseChapter(html, fallbackTitle: fallbackTitle) }.value
    }

    // MARK: Auswerten

    static func parseList(_ html: String) throws -> Page {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        var stories: [RemoteStory] = []
        for item in try doc.select("div.fiction-list-item").array() {
            guard let link = try item.select("h2.fiction-title a").first(),
                  let id = try link.attr("href").firstMatch(#"/fiction/(\d+)"#)?[1] else { continue }
            var s = RemoteStory(source: .royalRoad, sourceID: id, title: try link.text(), url: fictionURL(id))
            s.coverURL = try cover(item.select("figure img").first())
            s.tags = try item.select("a.fiction-tag").array().map { try $0.text() }
            let labels = try item.select("span.label").array().map { try $0.text().trimmed.uppercased() }
            s.isComplete = labels.contains("COMPLETED")
            s.genres = labels.contains("FAN FICTION") ? [String(localized: "Fanfiction")] : []
            for stat in try item.select("div.stats > div").array() {
                apply(stat: try stat.text(), to: &s)
                if let time = try stat.select("time").first() { s.updated = date(time) }
            }
            if let description = try item.select("div[id^=description-]").first() { s.summary = try AO3Service.paragraphText(description) }
            s.language = "English"
            stories.append(s)
        }
        let hasNext = try doc.select("ul.pagination a").array().contains { (try? $0.text().contains("Next")) == true }
        return Page(stories: stories, hasNext: hasNext)
    }

    /// „34,388 Followers“, „2,932 Pages“, „109 Chapters“, „28,837,937 Views“
    private static func apply(stat text: String, to s: inout RemoteStory) {
        guard let match = text.firstMatch(#"([\d,.]+)\s+(\w+)"#), let value = match[1].digitsInt else { return }
        switch match[2].lowercased() {
        case "followers": s.follows = value
        case "favorites": s.favs = value
        case "views": s.hits = value
        case "chapters": s.chapters = max(value, 1)
        // Royal Road rechnet 275 Wörter je Seite.
        case "pages": s.words = value * 275
        default: break
        }
    }

    private static func cover(_ img: Element?) throws -> URL? {
        guard let src = try img?.attr("src"), !src.isEmpty, !src.contains("nocover") else { return nil }
        // .webp und .jpg liegen nebeneinander – JPEG kann jeder Dekoder.
        return URL(string: src.replacingOccurrences(of: ".webp", with: ".jpg"), relativeTo: base)?.absoluteURL
    }

    private static func date(_ time: Element) -> Date? {
        if let unix = Double((try? time.attr("unixtime")) ?? "") { return Date(timeIntervalSince1970: unix) }
        let text = (try? time.attr("datetime")) ?? ""
        return DateParsing.iso.date(from: String(text.prefix(10)))
    }

    static func parseFiction(_ html: String, id: String) throws -> Fiction {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        guard let title = try doc.select("div.fic-title h1, div.fic-header h1").first()?.text(), !title.isEmpty else {
            throw BabelError.parsing("Royal Road")
        }
        var s = RemoteStory(source: .royalRoad, sourceID: id, title: title, url: fictionURL(id))
        if let author = try doc.select("div.fic-title h4 a, div.fic-header h4 a").first() {
            s.author = try author.text()
            s.authorURL = URL(string: try author.attr("href"), relativeTo: base)?.absoluteURL
        }
        s.coverURL = try cover(doc.select("img.thumbnail[data-type=cover]").first())
        if let description = try doc.select("div.description div.hidden-content").first() { s.summary = try AO3Service.paragraphText(description) }
        s.tags = try doc.select("span.tags a.fiction-tag").array().map { try $0.text() }
        let labels = try doc.select("div.fiction-info span.label").array().map { try $0.text().trimmed.uppercased() }
        s.isComplete = labels.contains("COMPLETED")
        s.genres = labels.contains("FAN FICTION") ? [String(localized: "Fanfiction")] : []
        s.language = "English"

        // Kennzahlen: „Total Views :“ und der Wert stehen als benachbarte Listenpunkte.
        let stats = try doc.select("div.stats-content li").array().map { try $0.text().trimmed }
        for (i, label) in stats.enumerated() where i + 1 < stats.count {
            guard let value = stats[i + 1].digitsInt else { continue }
            switch label.lowercased().replacingOccurrences(of: ":", with: "").trimmed {
            case "total views": s.hits = value
            case "followers": s.follows = value
            case "favorites": s.favs = value
            case "ratings": s.reviews = value
            case "pages": s.words = value * 275
            default: break
            }
        }

        // Die genaue Wortzahl steht im Hinweis neben der Seitenzahl.
        if let words = html.firstMatch(#"calculated from ([\d,]+) words"#)?[1].digitsInt { s.words = words }

        // Alle Kapitel stehen als JSON im Skript – die Tabelle zeigt nur einen Teil.
        var titles: [String] = []
        var paths: [String] = []
        var dates: [Date] = []
        if let json = html.firstMatch(#"window\.chapters\s*=\s*(\[.*?\]);"#)?[1], let data = json.data(using: .utf8) {
            struct Chapter: Decodable { let title: String; let url: String; let date: String?; let order: Int? }
            let chapters = ((try? JSONDecoder().decode([Chapter].self, from: data)) ?? []).sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            titles = chapters.map(\.title)
            paths = chapters.map(\.url)
            dates = chapters.compactMap { $0.date.flatMap { DateParsing.iso.date(from: String($0.prefix(10))) } }
        }
        if paths.isEmpty {
            for row in try doc.select("#chapters tbody tr").array() {
                guard let a = try row.select("a").first() else { continue }
                titles.append(try a.text())
                paths.append(try a.attr("href"))
            }
        }
        s.chapters = max(paths.count, 1)
        s.published = dates.min()
        s.updated = dates.max()
        return Fiction(meta: s, titles: titles, paths: paths)
    }

    static func parseChapter(_ html: String, fallbackTitle: String) throws -> ChapterContent {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        guard let content = try doc.select("div.chapter-inner.chapter-content").first() else {
            throw BabelError.parsing(String(localized: "Kapiteltext"))
        }
        // Die Seite blendet einzelne Absätze per CSS aus (Hinweise für Kopien auf fremden Seiten) –
        // sie gehören nicht zum Text, den Leser:innen dort sehen.
        for style in try doc.select("style").array() {
            let css = style.data()
            guard css.contains("display: none") || css.contains("display:none") else { continue }
            for match in css.allMatches(#"\.([A-Za-z0-9_-]+)\s*\{[^}]*display:\s*none"#) {
                _ = try? content.select("." + match[1]).remove()
            }
        }
        _ = try? content.select("script, style").remove()

        func note(_ element: Element) throws -> String {
            let body = try element.select("div.author-note").first()?.html() ?? ""
            guard !body.trimmed.isEmpty else { return "" }
            return "<aside class=\"babel-notes\"><div class=\"babel-notes-label\">\(String(localized: "Anmerkung"))</div>\(body)</aside>"
        }
        // Anmerkungen der Autor:in stehen vor oder hinter dem Text.
        var before = "", after = ""
        var seenContent = false
        for element in try doc.select("div.author-note-portlet, div.chapter-inner.chapter-content").array() {
            if element.hasClass("chapter-content") { seenContent = true; continue }
            if seenContent { after += try note(element) } else { before += try note(element) }
        }
        let title = try doc.select("div.fic-header h1, h1.break-word").first()?.text() ?? fallbackTitle
        return ChapterContent(title: title.isEmpty ? fallbackTitle : title, html: before + (try content.html()) + after)
    }
}
