import Foundation
import SwiftSoup

enum TriState: String, Codable, CaseIterable, Sendable, Hashable {
    case any, include, exclude
}

struct LanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }
}

struct AO3TagOption: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let short: String
}

enum AO3Sort: String, Codable, CaseIterable, Sendable, Hashable {
    case bestMatch = "_score"
    case updated = "revised_at"
    case posted = "created_at"
    case kudos = "kudos_count"
    case hits = "hits"
    case words = "word_count"
    case comments = "comments_count"
    case bookmarks = "bookmarks_count"
    case title = "title_to_sort_on"
    case author = "authors_to_sort_on"

    var label: String {
        switch self {
        case .bestMatch: String(localized: "Beste Treffer")
        case .updated: String(localized: "Zuletzt aktualisiert")
        case .posted: String(localized: "Veröffentlicht")
        case .kudos: String(localized: "Kudos")
        case .hits: String(localized: "Aufrufe")
        case .words: String(localized: "Wortanzahl")
        case .comments: String(localized: "Kommentare")
        case .bookmarks: String(localized: "Lesezeichen")
        case .title: String(localized: "Titel")
        case .author: String(localized: "Autor:in")
        }
    }
}

enum AO3Completion: String, Codable, CaseIterable, Sendable, Hashable {
    case any, complete, inProgress
    var label: String {
        switch self { case .any: String(localized: "Alle"); case .complete: String(localized: "Abgeschlossen"); case .inProgress: String(localized: "In Arbeit") }
    }
}

enum AO3Crossover: String, Codable, CaseIterable, Sendable, Hashable {
    case any, exclude, only
    var label: String {
        switch self { case .any: String(localized: "Egal"); case .exclude: String(localized: "Keine Crossover"); case .only: String(localized: "Nur Crossover") }
    }
}

enum AO3UpdatedWithin: String, Codable, CaseIterable, Sendable, Hashable {
    case any, week, month, halfYear, year
    var label: String {
        switch self {
        case .any: String(localized: "Jederzeit"); case .week: String(localized: "Letzte Woche"); case .month: String(localized: "Letzter Monat")
        case .halfYear: String(localized: "Letzte 6 Monate"); case .year: String(localized: "Letztes Jahr")
        }
    }
    var query: String? {
        switch self {
        case .any: nil; case .week: "< 7 days"; case .month: "< 1 month"
        case .halfYear: "< 6 months"; case .year: "< 1 year"
        }
    }
}

/// Alle Filter der AO3-Werksuche.
struct AO3Filters: Codable, Hashable, Sendable {
    var query = ""
    var title = ""
    var author = ""
    var fandoms: [String] = []
    var relationships: [String] = []
    var characters: [String] = []
    var freeforms: [String] = []
    var otherTags: [String] = []
    var excludedTags: [String] = []
    var ratings: [Int: TriState] = [:]
    var warnings: [Int: TriState] = [:]
    var categories: [Int: TriState] = [:]
    var completion: AO3Completion = .any
    var crossover: AO3Crossover = .any
    var singleChapter = false
    var language = ""
    var wordsFrom = ""
    var wordsTo = ""
    var minKudos = ""
    var updatedWithin: AO3UpdatedWithin = .any
    var sort: AO3Sort = .bestMatch
    var ascending = false

    /// Wie viele Filter (ohne Suchtext und Sortierung) aktiv sind.
    var activeCount: Int {
        var n = 0
        n += [title, author, language, wordsFrom, wordsTo, minKudos].filter { !$0.trimmed.isEmpty }.count
        n += [fandoms, relationships, characters, freeforms, otherTags, excludedTags].filter { !$0.isEmpty }.count
        n += ratings.values.filter { $0 != .any }.count
        n += warnings.values.filter { $0 != .any }.count
        n += categories.values.filter { $0 != .any }.count
        if completion != .any { n += 1 }
        if crossover != .any { n += 1 }
        if singleChapter { n += 1 }
        if updatedWithin != .any { n += 1 }
        return n
    }

    /// Kurzbeschreibung für gespeicherte Suchen.
    var summary: String {
        var parts: [String] = []
        if !query.trimmed.isEmpty { parts.append("„\(query.trimmed)“") }
        parts += fandoms + relationships + characters + freeforms + otherTags
        if completion == .complete { parts.append("abgeschlossen") }
        if !language.isEmpty { parts.append(language) }
        return parts.isEmpty ? String(localized: "Alle Werke") : parts.joined(separator: " · ")
    }
}

enum AO3Service {
    static let base = URL(string: "https://archiveofourown.org")!

    static let ratings: [AO3TagOption] = [
        .init(id: 10, name: "General Audiences", short: "G"),
        .init(id: 11, name: "Teen And Up Audiences", short: "T"),
        .init(id: 12, name: "Mature", short: "M"),
        .init(id: 13, name: "Explicit", short: "E"),
        .init(id: 9, name: "Not Rated", short: "NR"),
    ]

    static let warnings: [AO3TagOption] = [
        .init(id: 14, name: "Creator Chose Not To Use Archive Warnings", short: "CNTW"),
        .init(id: 16, name: String(localized: "No Archive Warnings Apply"), short: String(localized: "Keine")),
        .init(id: 17, name: "Graphic Depictions Of Violence", short: "Gewalt"),
        .init(id: 18, name: "Major Character Death", short: "MCD"),
        .init(id: 19, name: "Rape/Non-Con", short: "Non-Con"),
        .init(id: 20, name: "Underage Sex", short: "Underage"),
    ]

    static let categories: [AO3TagOption] = [
        .init(id: 116, name: "F/F", short: "F/F"),
        .init(id: 22, name: "F/M", short: "F/M"),
        .init(id: 21, name: "Gen", short: "Gen"),
        .init(id: 23, name: "M/M", short: "M/M"),
        .init(id: 2246, name: "Multi", short: "Multi"),
        .init(id: 24, name: "Other", short: "Other"),
    ]

    static let languages: [LanguageOption] = [
        .init(code: "", name: String(localized: "Alle Sprachen")), .init(code: "en", name: String(localized: "English")), .init(code: "de", name: String(localized: "Deutsch")), .init(code: "es", name: String(localized: "Español")),
        .init(code: "fr", name: "Français"), .init(code: "it", name: "Italiano"), .init(code: "ptBR", name: "Português brasileiro"),
        .init(code: "ru", name: "Русский"), .init(code: "pl", name: "Polski"), .init(code: "nl", name: "Nederlands"), .init(code: "sv", name: "Svenska"),
        .init(code: "tr", name: "Türkçe"), .init(code: "uk", name: "Українська"), .init(code: "vi", name: "Tiếng Việt"), .init(code: "id", name: "Bahasa Indonesia"),
        .init(code: "zh", name: "中文"), .init(code: "ja", name: "日本語"), .init(code: "ko", name: "한국어"),
    ]

    // MARK: - Laden (mit Ausweichweg über den WebView, falls Cloudflare dazwischenfunkt)

    static func fetchHTML(_ url: URL) async throws -> (html: String, finalURL: URL, status: Int) {
        let result = try await fetchHTMLRaw(url)
        if SiteStatus.isOutage(status: result.status) {
            throw BabelError.siteDown(site: "AO3", reason: SiteStatus.reason(status: result.status))
        }
        if let code = SiteStatus.errorPageCode(result.html) {
            let reason = SiteStatus.reason(status: code)
            await SiteStatus.shared.reportDown(host: base.host!, reason: reason)
            throw BabelError.siteDown(site: "AO3", reason: reason)
        }
        // AO3s eigene Wartungs-/Überlastungsseite
        if result.html.contains("archive is down for maintenance") || result.html.contains("Request temporarily denied") {
            let reason = String(localized: "ist gerade in Wartung")
            await SiteStatus.shared.reportDown(host: base.host!, reason: reason)
            throw BabelError.siteDown(site: "AO3", reason: reason)
        }
        return result
    }

    private static func fetchHTMLRaw(_ url: URL) async throws -> (html: String, finalURL: URL, status: Int) {
        // AO3 braucht unter Last teils über eine Minute für eine Seite – lieber warten als abbrechen.
        let result = try await HTTPClient.shared.html(url, timeout: 150)
        // Nur bei einer Cloudflare-Prüfung über den WebView – Serverfehler (5xx) sind echte Ausfälle.
        let blocked = result.status == 403 || result.html.contains("challenge-platform")
        guard blocked else { return result }
        let page = try await WebFetcher.shared.load(url, minInterval: 0.8)
        return (page.html, page.url, 200)
    }

    // MARK: - Suche

    static func searchURL(_ f: AO3Filters, page: Int) -> URL {
        var items: [URLQueryItem] = [URLQueryItem(name: "commit", value: "Search")]
        func add(_ key: String, _ value: String) {
            let v = value.trimmed
            if !v.isEmpty { items.append(URLQueryItem(name: "work_search[\(key)]", value: v)) }
        }
        func addArray(_ key: String, _ ids: [Int]) {
            for id in ids { items.append(URLQueryItem(name: "work_search[\(key)][]", value: String(id))) }
        }

        add("query", f.query)
        add("title", f.title)
        add("creators", f.author)
        add("fandom_names", f.fandoms.joined(separator: ","))
        add("relationship_names", f.relationships.joined(separator: ","))
        add("character_names", f.characters.joined(separator: ","))
        add("freeform_names", f.freeforms.joined(separator: ","))
        add("other_tag_names", f.otherTags.joined(separator: ","))
        add("excluded_tag_names", f.excludedTags.joined(separator: ","))

        var excluded: [Int] = []

        // Ratings: AO3 verknüpft Filter mit UND. Mehrere "Ja" → alle anderen ausschließen (= ODER).
        let includedRatings = ratings.map(\.id).filter { f.ratings[$0] == .include }
        if includedRatings.count == 1 {
            add("rating_ids", String(includedRatings[0]))
        } else if includedRatings.count > 1 {
            excluded += ratings.map(\.id).filter { !includedRatings.contains($0) }
        }
        excluded += ratings.map(\.id).filter { f.ratings[$0] == .exclude }

        addArray("archive_warning_ids", warnings.map(\.id).filter { f.warnings[$0] == .include })
        excluded += warnings.map(\.id).filter { f.warnings[$0] == .exclude }

        let includedCats = categories.map(\.id).filter { f.categories[$0] == .include }
        if includedCats.count == 1 {
            addArray("category_ids", includedCats)
        } else if includedCats.count > 1 {
            excluded += categories.map(\.id).filter { !includedCats.contains($0) }
        }
        excluded += categories.map(\.id).filter { f.categories[$0] == .exclude }

        addArray("excluded_tag_ids", Array(Set(excluded)).sorted())

        switch f.completion {
        case .any: break
        case .complete: add("complete", String(localized: "T"))
        case .inProgress: add("complete", String(localized: "F"))
        }
        switch f.crossover {
        case .any: break
        case .exclude: add("crossover", String(localized: "F"))
        case .only: add("crossover", String(localized: "T"))
        }
        if f.singleChapter { add("single_chapter", "1") }
        add("language_id", f.language)
        add("words_from", f.wordsFrom.filter(\.isNumber))
        add("words_to", f.wordsTo.filter(\.isNumber))
        if let k = f.minKudos.digitsInt { add("kudos_count", String(localized: "> \(max(k - 1, 0))")) }
        if let r = f.updatedWithin.query { add("revised_at", r) }
        add("sort_column", f.sort.rawValue)
        add("sort_direction", f.ascending ? "asc" : "desc")
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }

        var comps = URLComponents(url: base.appendingPathComponent("works/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        // "+" würde von Rails als Leerzeichen gelesen.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    struct ListPage: Sendable {
        var works: [RemoteStory]
        var total: Int?
        var hasNext: Bool
    }

    static func search(_ filters: AO3Filters, page: Int) async throws -> ListPage {
        let (html, _, status) = try await fetchHTML(searchURL(filters, page: page))
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) { try parseWorkList(html) }.value
    }

    /// Beliebige AO3-Listen-URL (Tag-Seite, Autor:in, Serie …).
    static func list(url: URL) async throws -> ListPage {
        let (html, _, status) = try await fetchHTML(url)
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) { try parseWorkList(html) }.value
    }

    // MARK: - Autovervollständigung

    enum TagKind: String, Sendable { case fandom, relationship, character, freeform, tag }

    /// Schon geladene Vorschläge (pro Art und Suchbegriff) – AO3 antwortet oft erst nach einer Sekunde.
    @MainActor private static var suggestionCache: [String: [String]] = [:]

    /// Sofort verfügbare Vorschläge aus dem Cache, auch aus einem kürzeren Begriff gefiltert.
    @MainActor
    static func cachedSuggestions(_ kind: TagKind, term: String) -> [String]? {
        let t = term.trimmed.lowercased()
        if let exact = suggestionCache["\(kind.rawValue):\(t)"] { return exact }
        var prefix = t
        while prefix.count > 2 {
            prefix.removeLast()
            if let list = suggestionCache["\(kind.rawValue):\(prefix)"] {
                let words = t.split(separator: " ")
                let filtered = list.filter { name in words.allSatisfy { name.lowercased().contains($0) } }
                if !filtered.isEmpty { return filtered }
            }
        }
        return nil
    }

    @MainActor
    static func autocomplete(_ kind: TagKind, term: String) async throws -> [String] {
        let t = term.trimmed
        guard t.count >= 2 else { return [] }
        let key = "\(kind.rawValue):\(t.lowercased())"
        if let hit = suggestionCache[key] { return hit }
        var comps = URLComponents(url: base.appendingPathComponent("autocomplete/\(kind.rawValue)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "term", value: t)]
        let (data, http) = try await HTTPClient.shared.data(
            comps.url!,
            headers: ["Accept": "application/json, text/javascript, */*", "X-Requested-With": "XMLHttpRequest"],
            minInterval: 0.15,
            bucket: "ao3-autocomplete",
            retries: 0,
            timeout: 15
        )
        guard http.statusCode == 200 else { return [] }
        struct Item: Decodable { let name: String }
        let names = (try? JSONDecoder().decode([Item].self, from: data).map(\.name)) ?? []
        suggestionCache[key] = names
        return names
    }

    // MARK: - Werk laden

    static func workURL(_ id: String, full: Bool) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("works/\(id)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "view_adult", value: "true")]
        if full { comps.queryItems?.append(URLQueryItem(name: "view_full_work", value: "true")) }
        return comps.url!
    }

    static func fetchWork(id: String) async throws -> (meta: RemoteStory, chapters: [ChapterContent]) {
        let html = try await fetchWorkPage(id: id, full: true)
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            return (try parseWorkMeta(doc, id: id), try parseChapters(doc))
        }.value
    }

    static func fetchWorkMeta(id: String) async throws -> RemoteStory {
        let html = try await fetchWorkPage(id: id, full: false)
        return try await Task.detached(priority: .userInitiated) {
            try parseWorkMeta(SwiftSoup.parse(html, base.absoluteString), id: id)
        }.value
    }

    private static func fetchWorkPage(id: String, full: Bool) async throws -> String {
        let (html, finalURL, status) = try await fetchHTML(workURL(id, full: full))
        if status == 404 { throw BabelError.notFound }
        if finalURL.path.contains("/users/login") || html.contains("only available to registered users") {
            throw BabelError.loginRequired
        }
        guard status == 200 else { throw BabelError.http(status) }
        return html
    }

    // MARK: - Konto (nur mit Anmeldung)

    enum AccountList: String, CaseIterable, Identifiable, Sendable {
        case bookmarks, markedForLater, subscriptions, history
        var id: String { rawValue }

        var label: String {
            switch self {
            case .bookmarks: String(localized: "Lesezeichen")
            case .markedForLater: String(localized: "Später lesen")
            case .subscriptions: String(localized: "Abonnements")
            case .history: String(localized: "Verlauf")
            }
        }

        var symbol: String {
            switch self {
            case .bookmarks: "bookmark.fill"
            case .markedForLater: "clock.fill"
            case .subscriptions: "bell.fill"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    /// Name der angemeldeten Person aus der Begrüßung oben auf jeder AO3-Seite – `nil`, wenn nicht angemeldet.
    static func currentUsername() async throws -> String? {
        let (html, _, _) = try await fetchHTML(base.appendingPathComponent("menu/browse"))
        guard let greeting = html.range(of: "id=\"greeting\"") else { return nil }
        let tail = String(html[greeting.lowerBound...].prefix(3000))
        return tail.firstMatch(#"href="/users/([^/"?]+)"#)?[1].removingPercentEncoding
    }

    static func accountURL(_ list: AccountList, user: String, page: Int) -> URL {
        let userPath = base.appendingPathComponent("users/\(user)")
        var comps: URLComponents
        switch list {
        case .bookmarks:
            comps = URLComponents(url: userPath.appendingPathComponent("bookmarks"), resolvingAgainstBaseURL: false)!
        case .markedForLater:
            comps = URLComponents(url: userPath.appendingPathComponent("readings"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "show", value: "to-read")]
        case .history:
            comps = URLComponents(url: userPath.appendingPathComponent("readings"), resolvingAgainstBaseURL: false)!
        case .subscriptions:
            comps = URLComponents(url: userPath.appendingPathComponent("subscriptions"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "type", value: "works")]
        }
        if page > 1 { comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "page", value: String(page))] }
        return comps.url!
    }

    static func accountList(_ list: AccountList, user: String, page: Int) async throws -> ListPage {
        let (html, finalURL, status) = try await fetchHTML(accountURL(list, user: user, page: page))
        if finalURL.path.contains("/users/login") { throw BabelError.loginRequired }
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) {
            var result = try parseWorkList(html)
            if result.works.isEmpty { result.works = try parseWorkLinks(html) }
            return result
        }.value
    }

    /// Für Seiten ohne Werk-Kästen (z. B. Abonnements): nur Titel, Link und Autor:in.
    static func parseWorkLinks(_ html: String) throws -> [RemoteStory] {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        var seen = Set<String>()
        var works: [RemoteStory] = []
        for a in try doc.select("#main a[href^=\"/works/\"]").array() {
            guard let id = try a.attr("href").firstMatch(#"^/works/(\d+)/?$"#)?[1], !seen.contains(id) else { continue }
            let title = try a.text().trimmed
            guard !title.isEmpty else { continue }
            seen.insert(id)
            var story = RemoteStory(source: .ao3, sourceID: id, title: title, url: base.appendingPathComponent("works/\(id)"))
            if let row = a.parent(), let author = try row.select("a[rel=author]").first() {
                story.author = try author.text()
            }
            works.append(story)
        }
        return works
    }

    // MARK: - Autor:innen

    /// "/users/NAME/pseuds/PSEUD" → "NAME"
    static func username(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "users"), i + 1 < parts.count else { return nil }
        return parts[i + 1].removingPercentEncoding ?? parts[i + 1]
    }

    static func authorProfile(user: String) async throws -> AuthorProfile {
        let url = base.appendingPathComponent("users/\(user)/profile")
        let (html, _, status) = try await fetchHTML(url)
        if status == 404 { throw BabelError.notFound }
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            var p = AuthorProfile(name: user, url: base.appendingPathComponent("users/\(user)"))
            p.bio = try doc.select("div.bio blockquote.userstuff").first().map { try paragraphText($0) } ?? ""
            let dts = try doc.select("dl.meta dt").array(), dds = try doc.select("dl.meta dd").array()
            for (dt, dd) in zip(dts, dds) where try dt.text().contains("joined") {
                p.joined = DateParsing.iso.date(from: try dd.text())
            }
            for a in try doc.select("#dashboard a").array() {
                let text = try a.text()
                let n = text.firstMatch(#"\((\d[\d,]*)\)"#)?[1].digitsInt
                if text.hasPrefix("Works") { p.storyCount = n }
                if text.hasPrefix("Bookmarks") { p.favoriteCount = n }
            }
            return p
        }.value
    }

    enum AuthorList: Sendable { case works, bookmarks }

    static func authorList(_ list: AuthorList, user: String, page: Int) async throws -> ListPage {
        var comps = URLComponents(url: base.appendingPathComponent("users/\(user)/\(list == .works ? "works" : "bookmarks")"),
                                  resolvingAgainstBaseURL: false)!
        if page > 1 { comps.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        return try await self.list(url: comps.url!)
    }

    // MARK: - Parser

    static func parseWorkList(_ html: String) throws -> ListPage {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        var works: [RemoteStory] = []
        for li in try doc.select("li.work.blurb, li.bookmark.blurb") {
            if let w = try? parseBlurb(li) { works.append(w) }
        }
        let hasNext = !(try doc.select("ol.pagination li.next a").array().isEmpty)
        var total: Int?
        if let heading = try doc.select("#main h3.heading, #main h2.heading").first()?.text(),
           let m = heading.firstMatch(#"([\d,\.]+)\s+(Works|Bookmarked)"#) ?? heading.firstMatch(#"of\s+([\d,\.]+)"#) {
            total = m[1].digitsInt
        }
        return ListPage(works: works, total: total, hasNext: hasNext)
    }

    static func parseBlurb(_ li: Element) throws -> RemoteStory? {
        guard let link = try li.select("h4.heading a[href^=\"/works/\"]").first(),
              let id = try link.attr("href").firstMatch(#"/works/(\d+)"#)?[1] else { return nil }

        func texts(_ sel: String) throws -> [String] { try li.select(sel).array().map { try $0.text() } }
        func stat(_ cls: String) throws -> Int? { try li.select("dl.stats dd.\(cls)").first()?.text().digitsInt }

        let authors = try texts("h4.heading a[rel=author]")
        let chaptersText = try li.select("dl.stats dd.chapters").first()?.text() ?? "1/1"
        let (chapters, total) = parseChapterFraction(chaptersText)
        let iswip = try li.select("ul.required-tags span.iswip").first()?.attr("title") ?? ""

        var story = RemoteStory(
            source: .ao3, sourceID: id, title: try link.text(),
            url: base.appendingPathComponent("works/\(id)")
        )
        story.author = authors.isEmpty ? "Anonym" : authors.joined(separator: ", ")
        if let a = try li.select("h4.heading a[rel=author]").first() {
            story.authorURL = URL(string: try a.attr("href"), relativeTo: base)?.absoluteURL
        }
        story.fandoms = try texts("h5.fandoms a.tag")
        story.rating = try li.select("ul.required-tags span.rating").first()?.attr("title") ?? ""
        let cats = try li.select("ul.required-tags span.category").first()?.attr("title") ?? ""
        story.categories = cats.components(separatedBy: ", ").filter { !$0.isEmpty && $0 != "No category" }
        story.warnings = try texts("ul.tags li.warnings a.tag")
        story.relationships = try texts("ul.tags li.relationships a.tag")
        story.characters = try texts("ul.tags li.characters a.tag")
        story.tags = try texts("ul.tags li.freeforms a.tag")
        if let summary = try li.select("blockquote.summary").first() { story.summary = try paragraphText(summary) }
        story.language = try li.select("dl.stats dd.language").first()?.text() ?? ""
        story.words = try stat("words")
        story.chapters = chapters
        story.totalChapters = total
        story.isComplete = iswip.contains("Complete") || (total != nil && total == chapters)
        story.kudos = try stat("kudos")
        story.hits = try stat("hits")
        story.comments = try stat("comments")
        story.bookmarks = try stat("bookmarks")
        if let d = try li.select("p.datetime").first()?.text() { story.updated = DateParsing.ao3Blurb.date(from: d) }
        return story
    }

    static func parseWorkMeta(_ doc: Document, id: String) throws -> RemoteStory {
        func tags(_ cls: String) throws -> [String] {
            try doc.select("dl.work.meta dd.\(cls).tags a.tag").array().map { try $0.text() }
        }
        func stat(_ cls: String) throws -> Int? { try doc.select("dl.stats dd.\(cls)").first()?.text().digitsInt }

        guard let title = try doc.select("div.preface.group h2.title").first()?.text() else {
            throw BabelError.parsing("AO3-Werk")
        }
        var story = RemoteStory(source: .ao3, sourceID: id, title: title, url: base.appendingPathComponent("works/\(id)"))
        let authors = try doc.select("div.preface.group h3.byline a[rel=author]").array().map { try $0.text() }
        story.author = authors.isEmpty ? "Anonym" : authors.joined(separator: ", ")
        if let a = try doc.select("div.preface.group h3.byline a[rel=author]").first() {
            story.authorURL = URL(string: try a.attr("href"), relativeTo: base)?.absoluteURL
        }
        if let s = try doc.select("div.preface.group div.summary blockquote.userstuff").first() {
            story.summary = try paragraphText(s)
        }
        story.rating = try tags("rating").joined(separator: ", ")
        story.warnings = try tags("warning")
        story.categories = try tags("category")
        story.fandoms = try tags("fandom")
        story.relationships = try tags("relationship")
        story.characters = try tags("character")
        story.tags = try tags("freeform")
        story.language = try doc.select("dl.work.meta dd.language").first()?.text() ?? ""
        let (chapters, total) = parseChapterFraction(try doc.select("dl.stats dd.chapters").first()?.text() ?? "1/1")
        story.chapters = chapters
        story.totalChapters = total
        story.isComplete = total != nil && total == chapters
        story.words = try stat("words")
        story.kudos = try stat("kudos")
        story.hits = try stat("hits")
        story.comments = try stat("comments")
        story.bookmarks = try stat("bookmarks")
        if let p = try doc.select("dl.stats dd.published").first()?.text() { story.published = DateParsing.iso.date(from: p) }
        if let u = try doc.select("dl.stats dd.status").first()?.text() {
            story.updated = DateParsing.iso.date(from: u)
        } else {
            story.updated = story.published
        }
        return story
    }

    static func parseChapters(_ doc: Document) throws -> [ChapterContent] {
        var result: [ChapterContent] = []
        let workNotes = try doc.select("#workskin > div.preface.group div.notes.module blockquote.userstuff").first()?.html()
        let workEndNotes = try doc.select("#workskin div.afterword div.end.notes blockquote.userstuff").first()?.html()
        let workTitle = try doc.select("div.preface.group h2.title").first()?.text() ?? String(localized: "Kapitel 1")

        let chapterDivs = try doc.select("#chapters > div.chapter").array()
        if chapterDivs.isEmpty {
            guard let body = try doc.select("#chapters > div.userstuff").first() ?? doc.select("#chapters").first() else {
                throw BabelError.parsing("Kapiteltext")
            }
            try body.select("h3.landmark").remove()
            result.append(ChapterContent(title: workTitle, html: assemble(notes: workNotes, body: try body.html(), endNotes: workEndNotes)))
            return result
        }

        for (i, div) in chapterDivs.enumerated() {
            var title = try div.select("h3.title").first()?.text() ?? ""
            if let m = title.firstMatch(#"^Chapter\s+\d+\s*:?\s*(.*)$"#) { title = m[1].trimmed }
            if title.isEmpty { title = String(localized: "Kapitel \(i + 1)") }

            let notes = try div.select("div.chapter.preface div.notes blockquote.userstuff").first()?.html()
            let endNotes = try div.select("div.end.notes blockquote.userstuff").first()?.html()
            guard let content = try div.select("div.userstuff.module").first() ?? div.select("div.userstuff").first() else { continue }
            try content.select("h3.landmark").remove()

            let isFirst = i == 0, isLast = i == chapterDivs.count - 1
            let combinedNotes = [isFirst ? workNotes : nil, notes].compactMap { $0 }.joined(separator: "<hr>")
            let combinedEnd = [endNotes, isLast ? workEndNotes : nil].compactMap { $0 }.joined(separator: "<hr>")
            result.append(ChapterContent(
                title: title,
                html: assemble(notes: combinedNotes.isEmpty ? nil : combinedNotes,
                               body: try content.html(),
                               endNotes: combinedEnd.isEmpty ? nil : combinedEnd)
            ))
        }
        return result
    }

    private static func assemble(notes: String?, body: String, endNotes: String?) -> String {
        var html = ""
        if let notes { html += "<aside class=\"babel-notes\"><div class=\"babel-notes-label\">\(String(localized: "Notizen"))</div>\(notes)</aside>" }
        html += body
        if let endNotes { html += "<aside class=\"babel-notes end\"><div class=\"babel-notes-label\">\(String(localized: "Notizen am Ende"))</div>\(endNotes)</aside>" }
        return html
    }

    static func parseChapterFraction(_ text: String) -> (Int, Int?) {
        let parts = text.split(separator: "/").map { String($0).trimmed }
        let current = parts.first?.digitsInt ?? 1
        let total = parts.count > 1 ? parts[1].digitsInt : nil
        return (current, total)
    }

    /// Text mit Absätzen aus einem HTML-Block.
    static func paragraphText(_ el: Element) throws -> String {
        let ps = try el.select("p").array()
        if ps.isEmpty { return try el.text() }
        return try ps.map { try $0.text() }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
