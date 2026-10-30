import Foundation
import SwiftSoup

struct FFNCategory: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
}

struct FFNFandom: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var path: String
    var countText: String = ""
    var id: String { path }

    /// "12.3K" → 12300 (für Sortierung nach Beliebtheit)
    var countValue: Double {
        let t = countText.uppercased().replacingOccurrences(of: ",", with: "")
        let num = Double(t.filter { $0.isNumber || $0 == "." }) ?? 0
        if t.contains("K") { return num * 1_000 }
        if t.contains("M") { return num * 1_000_000 }
        return num
    }

    var url: URL { URL(string: path, relativeTo: FFNService.base)!.absoluteURL }
}

struct FFNOption: Identifiable, Hashable, Sendable {
    let value: String
    let text: String
    var id: String { value }
}

/// Ein Filter-Dropdown, so wie FanFiction.net ihn auf der Seite anbietet.
struct FFNFilterSelect: Identifiable, Hashable, Sendable {
    let name: String
    let label: String
    let options: [FFNOption]
    var selected: String
    var id: String { name }
    var isExclusion: Bool { name.hasPrefix("_") }
}

struct FFNListPage: Sendable {
    var stories: [RemoteStory]
    var filters: [FFNFilterSelect]
    var url: URL
    var hasNext: Bool
}

enum FFNService {
    static let base = URL(string: "https://www.fanfiction.net")!

    static let categories: [FFNCategory] = [
        .init(id: "anime", name: String(localized: "Anime/Manga"), symbol: "sparkles"),
        .init(id: "book", name: String(localized: "Bücher"), symbol: "book.closed"),
        .init(id: "cartoon", name: String(localized: "Cartoons"), symbol: "paintpalette"),
        .init(id: "comic", name: String(localized: "Comics"), symbol: "bubble.left.and.bubble.right"),
        .init(id: "game", name: String(localized: "Games"), symbol: "gamecontroller"),
        .init(id: "misc", name: String(localized: "Sonstiges"), symbol: "square.grid.2x2"),
        .init(id: "movie", name: String(localized: "Filme"), symbol: "film"),
        .init(id: "play", name: String(localized: "Theater/Musicals"), symbol: "theatermasks"),
        .init(id: "tv", name: String(localized: "TV-Serien"), symbol: "tv"),
    ]

    static let knownGenres: Set<String> = [
        "Adventure", "Angst", "Crime", "Drama", "Family", "Fantasy", "Friendship", "General",
        "Horror", "Humor", "Hurt/Comfort", "Mystery", "Parody", "Poetry", "Romance", "Sci-Fi",
        "Spiritual", "Supernatural", "Suspense", "Tragedy", "Western",
    ]

    // MARK: - Fandoms

    static func fandoms(category: String) async throws -> [FFNFandom] {
        let (html, _) = try await load(base.appendingPathComponent("\(category)/"))
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            var links = try doc.select("#list_output a[href]").array()
            if links.isEmpty { links = try doc.select("a[href^=\"/\(category)/\"]").array() }
            var seen = Set<String>()
            var result: [FFNFandom] = []
            for a in links {
                let href = try a.attr("href")
                let comps = href.split(separator: "/").map(String.init)
                guard comps.count == 2, comps[0] == category, !seen.contains(href) else { continue }
                seen.insert(href)
                let title = try a.attr("title")
                let name = try title.isEmpty ? a.text() : title
                var count = ""
                if let sib = try a.nextElementSibling(), sib.tagName() == "span" {
                    count = try sib.text().trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                }
                result.append(FFNFandom(name: name, path: href, countText: count))
            }
            if result.isEmpty { throw BabelError.parsing("Fandom-Liste") }
            return result
        }.value
    }

    // MARK: - Geschichten-Listen

    /// m.fanfiction.net → www.fanfiction.net (die mobile Seite hat ein anderes HTML).
    static func desktopURL(_ url: URL) -> URL? {
        guard url.host == "m.fanfiction.net", var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.host = "www.fanfiction.net"
        return comps.url
    }

    /// Lädt über den WebView und landet garantiert auf der Desktop-Seite.
    static func load(_ url: URL, minInterval: Double = 1.2) async throws -> (html: String, url: URL) {
        let page = try await WebFetcher.shared.load(desktopURL(url) ?? url, minInterval: minInterval)
        if let desktop = desktopURL(page.url) { return try await WebFetcher.shared.load(desktop, minInterval: minInterval) }
        return page
    }

    static func list(url: URL) async throws -> FFNListPage {
        let (html, finalURL) = try await load(url)
        let page = try await parseListOffMain(html, url: finalURL)
        // Keine Geschichten *und* keine Filter: Das war keine fertige Listen-Seite – noch einmal laden.
        if page.stories.isEmpty, page.filters.isEmpty {
            let (html, finalURL) = try await load(url, minInterval: 2)
            return try await parseListOffMain(html, url: finalURL)
        }
        return page
    }

    static func list(url: URL, page: Int) async throws -> FFNListPage {
        try await list(url: setPage(withDefaultRating(url), page: page))
    }

    /// Worin die FFN-Suche sucht. FFN selbst nimmt sonst „any“: dann reicht ein einzelnes Wort,
    /// und exakte Titel gehen in den Treffern unter.
    enum SearchMatch: String, CaseIterable, Sendable {
        case title, summary, any
        var label: String {
            switch self { case .title: String(localized: "Titel"); case .summary: String(localized: "Zusammenfassung"); case .any: String(localized: "Beides") }
        }
    }

    static func search(keywords: String, match: SearchMatch = .title, page: Int) async throws -> FFNListPage {
        var comps = URLComponents(url: base.appendingPathComponent("search/"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "keywords", value: keywords.trimmed),
            URLQueryItem(name: "ready", value: "1"),
            URLQueryItem(name: "type", value: "story"),
            URLQueryItem(name: "match", value: match.rawValue),
        ]
        if page > 1 { comps.queryItems?.append(URLQueryItem(name: "ppage", value: String(page))) }
        var result = try await list(url: comps.url!)
        if page == 1 { result.stories = TitleRanking.rank(result.stories, query: keywords) }
        return result
    }

    /// Filter anwenden: genau die URL bauen, die FFNs eigenes `process_filter()` bauen würde.
    /// (Früher per JS-Klick auf „Apply“ – langsamer und wackliger.)
    static func applyFilters(on pageURL: URL, values: [String: String]) async throws -> FFNListPage {
        try await list(url: filterURL(pageURL, values: values))
    }

    /// Name des Formularfelds → URL-Parameter (aus FFNs `process_filter()`).
    private static let paramNames: [String: String] = [
        "sortid": "srt", "timerange": "t", "timeid": "t", "genreid1": "g1", "genreid2": "g2", "_genreid1": "_g1",
        "censorid": "r", "languageid": "lan", "length": "len", "statusid": "s",
        "characterid1": "c1", "characterid2": "c2", "characterid3": "c3", "characterid4": "c4",
        "_characterid1": "_c1", "_characterid2": "_c2", "verseid1": "v1", "_verseid1": "_v1",
        "pm": "pm", "_pm": "_pm",
    ]

    /// Wie FFN: nur Werte > 0 kommen in die URL.
    static func filterURL(_ pageURL: URL, values: [String: String]) -> URL {
        var comps = URLComponents(url: setPage(pageURL, page: 1), resolvingAgainstBaseURL: false)!
        let known = Set(paramNames.values)
        var items = (comps.queryItems ?? []).filter { !known.contains($0.name) }
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let param = paramNames[name], let n = Int(value), n > 0 else { continue }
            items.append(URLQueryItem(name: param, value: value))
        }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url ?? pageURL
    }

    /// FFN zeigt ohne Rating-Filter nur K–T. Mit der Einstellung „Alle Ratings“ kommt M dazu (`r=10`).
    static let allRatingsKey = "ffn.allRatings"
    static func withDefaultRating(_ url: URL) -> URL {
        guard UserDefaults.standard.bool(forKey: allRatingsKey),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(comps.queryItems ?? []).contains(where: { $0.name == "r" }),
              !comps.path.hasPrefix("/search") else { return url }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "r", value: "10")]
        return comps.url ?? url
    }

    static func setPage(_ url: URL, page: Int) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let key = comps.path.hasPrefix("/search") ? "ppage" : "p"
        var items = (comps.queryItems ?? []).filter { $0.name != key }
        if page > 1 { items.append(URLQueryItem(name: key, value: String(page))) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url ?? url
    }

    private static func parseListOffMain(_ html: String, url: URL) async throws -> FFNListPage {
        try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            let stories = try parseStories(doc)
            let filters = try parseFilters(doc)
            let hasNext = try doc.select("a").array().contains { (try? $0.text().hasPrefix("Next")) ?? false }
            return FFNListPage(stories: stories, filters: filters, url: url, hasNext: hasNext || stories.count >= 25)
        }.value
    }

    static func parseStories(_ doc: Document, selector: String = "div.z-list") throws -> [RemoteStory] {
        var result: [RemoteStory] = []
        for z in try doc.select(selector).array() {
            guard let a = try z.select("a.stitle").first() else { continue }
            let href = try a.attr("href")
            guard let id = href.firstMatch(#"/s/(\d+)"#)?[1] else { continue }
            var story = RemoteStory(source: .ffn, sourceID: id, title: try a.text(),
                                    url: base.appendingPathComponent("s/\(id)/1/"))
            if let author = try z.select("a[href^=\"/u/\"]").first() {
                story.author = try author.text()
                story.authorURL = URL(string: try author.attr("href"), relativeTo: base)?.absoluteURL
            }
            if let img = try z.select("img.cimage").first() {
                let original = try img.attr("data-original")
                let src = try original.isEmpty ? img.attr("src") : original
                // "/static/images/d_60_90.jpg" ist nur FFNs Platzhalter-Silhouette.
                if !src.isEmpty, !src.contains("/static/") { story.coverURL = URL(string: src, relativeTo: base)?.absoluteURL }
            }
            if let indent = try z.select("div.z-indent").first() {
                if let metaEl = try indent.select("div.z-padtop2").first() {
                    let dates = try metaEl.select("span[data-xutime]").array().compactMap { Double(try $0.attr("data-xutime")) }
                    applyMeta(try metaEl.text(), dates: dates, to: &story)
                    try metaEl.remove()
                }
                story.summary = try indent.text()
            }
            result.append(story)
        }
        return result
    }

    static func parseFilters(_ doc: Document) throws -> [FFNFilterSelect] {
        var result: [FFNFilterSelect] = []
        var seen = Set<String>()
        for sel in try doc.select("select[name]").array() {
            let name = try sel.attr("name")
            guard !name.isEmpty, name != "chapter", sel.id() != "chap_select", !seen.contains(name) else { continue }
            var options = try sel.select("option").array().map {
                FFNOption(value: try $0.attr("value"), text: try $0.text())
            }
            // "(? Ratings Guide)" ist ein Link, keine Auswahl.
            options.removeAll { $0.text.hasPrefix("(?") }
            guard options.count > 1 else { continue }
            seen.insert(name)
            let selected = try sel.select("option[selected]").first()?.attr("value") ?? options[0].value
            var label = options[0].text
            if let colon = label.firstIndex(of: ":") { label = String(label[..<colon]) }
            label = label.trimmed
            // "Sort: Update Date" → "Update Date" – das Etikett steht schon links.
            options = options.map { o in
                o.text.hasPrefix(label + ": ") ? FFNOption(value: o.value, text: String(o.text.dropFirst(label.count + 2))) : o
            }
            if name.hasPrefix("_") { label = String(localized: "Ohne: \(label)") }
            result.append(FFNFilterSelect(name: name, label: label, options: options, selected: selected))
        }
        // „Pairing“-Häkchen: gewählte Charaktere müssen ein Paar sein (bzw. bei _pm: dürfen keins sein).
        for box in try doc.select("input[type=checkbox][name=pm], input[type=checkbox][name=_pm]").array() {
            let name = try box.attr("name")
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            let on = box.hasAttr("checked")
            result.append(FFNFilterSelect(
                name: name,
                label: name == "pm" ? String(localized: "Pairing") : String(localized: "Ohne: Pairing"),
                options: [FFNOption(value: "0", text: String(localized: "Aus")), FFNOption(value: "1", text: String(localized: "An"))],
                selected: on ? "1" : "0"))
        }
        return result
    }

    /// "Rated: T - English - Romance/Drama - Chapters: 10 - Words: 30,000 - … - Harry P., Hermione G. - Complete"
    static func applyMeta(_ text: String, dates: [Double], to story: inout RemoteStory) {
        let parts = text.replacingOccurrences(of: "Hurt/Comfort", with: "Hurt-Comfort")
            .components(separatedBy: " - ").map(\.trimmed).filter { !$0.isEmpty }
        var seenRating = false
        var languageSet = false
        var fandomParts: [String] = []
        var characterText: [String] = []

        for part in parts {
            if part.hasPrefix("Rated:") {
                seenRating = true
                story.rating = part.replacingOccurrences(of: "Rated:", with: "")
                    .replacingOccurrences(of: "Fiction", with: "").trimmed
                continue
            }
            if !seenRating { fandomParts.append(part); continue }
            if part == "Complete" || part == "Status: Complete" { story.isComplete = true; continue }
            if let colon = part.firstIndex(of: ":") {
                let key = String(part[..<colon]).trimmed
                let value = String(part[part.index(after: colon)...]).trimmed
                switch key {
                case "Chapters": story.chapters = value.digitsInt ?? 1
                case "Words": story.words = value.digitsInt
                case "Reviews": story.reviews = value.digitsInt
                case "Favs": story.favs = value.digitsInt
                case "Follows": story.follows = value.digitsInt
                case "Updated", "Published", "id", "Status": break
                default: characterText.append(part)
                }
                continue
            }
            if !languageSet { story.language = part; languageSet = true; continue }
            let genreCandidates = part.split(separator: "/").map { String($0).replacingOccurrences(of: "Hurt-Comfort", with: "Hurt/Comfort") }
            if story.genres.isEmpty, genreCandidates.allSatisfy({ knownGenres.contains($0) }) {
                story.genres = genreCandidates
            } else {
                characterText.append(part)
            }
        }

        // Fandoms (bei Suche/Crossover steht das vor "Rated:")
        let fandomText = fandomParts.filter { $0 != "Crossover" }.joined(separator: " - ")
        if !fandomText.isEmpty {
            story.fandoms = fandomText.components(separatedBy: " & ").map(\.trimmed).filter { !$0.isEmpty }
        }

        // Charaktere und Pairings in [eckigen Klammern]
        let chars = characterText.joined(separator: ", ")
        var ships: [String] = []
        var rest = chars
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            ships.append(rest[rest.index(after: open)..<close].replacingOccurrences(of: ", ", with: "/"))
            rest.removeSubrange(open...close)
        }
        story.relationships = ships
        story.characters = chars.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ",")
            .split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }

        let sorted = dates.sorted()
        if let first = sorted.first { story.published = Date(timeIntervalSince1970: first) }
        if let last = sorted.last { story.updated = Date(timeIntervalSince1970: last) }
        if story.chapters == 0 { story.chapters = 1 }
        if story.isComplete { story.totalChapters = story.chapters }
    }

    // MARK: - Autor:innen

    /// Profilseite: eigene Geschichten und Favoriten stehen beide auf `/u/<id>/`.
    static func authorProfile(url: URL) async throws -> AuthorProfile {
        let (html, finalURL) = try await load(url)
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            let name = try doc.select("#content_wrapper_inner span[style*=font-size]").first()?.text().trimmed ?? ""
            var p = AuthorProfile(name: name.isEmpty ? String(localized: "Autor:in") : name, url: finalURL)
            if let first = try doc.select("#content_wrapper_inner span[data-xutime]").first(),
               let t = Double(try first.attr("data-xutime")) {
                p.joined = Date(timeIntervalSince1970: t)
            }
            if let bio = try doc.select("#bio").first() {
                try bio.select("img").remove()
                p.bio = try bio.text().trimmed
            }
            p.stories = try parseStories(doc, selector: "div.z-list.mystories")
            p.favorites = try parseStories(doc, selector: "div.z-list.favstories")
            p.storyCount = p.stories.count
            p.favoriteCount = p.favorites.count
            return p
        }.value
    }

    // MARK: - Konto (nur mit Anmeldung)

    enum AccountList: String, CaseIterable, Identifiable, Sendable {
        case favorites, follows
        var id: String { rawValue }
        var label: String { self == .favorites ? String(localized: "Favoriten") : String(localized: "Follows") }
        var symbol: String { self == .favorites ? "heart.fill" : "bell.fill" }
        var path: String { self == .favorites ? "favorites/story.php" : "alert/story.php" }
    }

    /// Name der angemeldeten Person – FFN schreibt ihn oben rechts neben „Logout“ (`#name_login`).
    /// `nil` heißt: nicht angemeldet.
    static func currentUsername() async throws -> String? {
        let (html, _) = try await load(base, minInterval: 0.8)
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            guard let box = try doc.select("#name_login").first(), try box.text().contains("Logout"),
                  let name = try box.select("a").first()?.text().trimmed, !name.isEmpty else { return nil }
            return name
        }.value
    }

    /// Favoriten oder Follows der angemeldeten Person.
    /// Favoriten kommen vom öffentlichen Profil (`/~name`, sauberes `z-list favstories`),
    /// Follows nur über die Konto-Seite.
    static func accountList(_ list: AccountList, username: String) async throws -> [RemoteStory] {
        if list == .favorites, !username.isEmpty,
           let profile = URL(string: "~" + (username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username), relativeTo: base) {
            let (html, _) = try await load(profile.absoluteURL)
            let favorites = try await Task.detached(priority: .userInitiated) {
                try parseStories(SwiftSoup.parse(html, base.absoluteString), selector: "div.z-list.favstories")
            }.value
            if !favorites.isEmpty { return favorites }
        }
        return try await accountPages(list)
    }

    private static func accountPages(_ list: AccountList) async throws -> [RemoteStory] {
        var url: URL? = base.appendingPathComponent(list.path)
        var result: [RemoteStory] = []
        var seen = Set<String>()
        var pages = 0
        while let current = url, pages < 30 {
            pages += 1
            var (html, finalURL) = try await load(current)
            if finalURL.path.contains("login") { throw BabelError.ffnLoginRequired }
            // Konto-Seiten bauen ihre Listen teils erst per Skript auf – dann kurz warten und neu lesen.
            if !html.contains("/s/") {
                try? await Task.sleep(for: .seconds(2))
                html = await WebFetcher.shared.currentHTML() ?? html
            }
            let pageHTML = html
            let parsed = try await Task.detached(priority: .userInitiated) { () -> ([RemoteStory], URL?) in
                let doc = try SwiftSoup.parse(pageHTML, base.absoluteString)
                var stories = try parseStories(doc)
                if stories.isEmpty { stories = try parseStoryLinks(doc) }
                let next = try doc.select("a").array().first { (try? $0.text().trimmed.hasPrefix("Next")) ?? false }
                let nextURL = try next.flatMap { URL(string: try $0.attr("href"), relativeTo: finalURL)?.absoluteURL }
                return (stories, nextURL)
            }.value
            let fresh = parsed.0.filter { seen.insert($0.sourceID).inserted }
            result += fresh
            url = fresh.isEmpty ? nil : parsed.1
        }
        return result
    }

    /// Tabellen ohne `z-list` (Konto-Seiten): Titel, Link und Autor:in aus jeder Zeile.
    static func parseStoryLinks(_ doc: Document) throws -> [RemoteStory] {
        var result: [RemoteStory] = []
        var seen = Set<String>()
        for a in try doc.select("a[href*=\"/s/\"]").array() {
            let href = try a.attr("href")
            guard href.hasPrefix("/s/") || href.contains("fanfiction.net/s/"),
                  let id = href.firstMatch(#"/s/(\d+)"#)?[1], !seen.contains(id) else { continue }
            let title = try a.text().trimmed
            guard !title.isEmpty, title.rangeOfCharacter(from: .letters) != nil else { continue }
            seen.insert(id)
            var story = RemoteStory(source: .ffn, sourceID: id, title: title, url: base.appendingPathComponent("s/\(id)/1/"))
            var row: Element? = a.parent()
            while let r = row, r.tagName() != "tr", r.tagName() != "div", r.tagName() != "li" { row = r.parent() }
            if let row, let author = try row.select("a[href^=\"/u/\"]").first() {
                story.author = try author.text()
                story.authorURL = URL(string: try author.attr("href"), relativeTo: base)?.absoluteURL
            }
            result.append(story)
        }
        return result
    }

    // MARK: - Kapitel

    static func chapterURL(storyID: String, number: Int) -> URL {
        base.appendingPathComponent("s/\(storyID)/\(number)/")
    }

    static func chapter(storyID: String, number: Int) async throws -> (meta: RemoteStory, titles: [String], content: ChapterContent) {
        let (html, _) = try await load(chapterURL(storyID: storyID, number: number))
        if html.contains("Story Not Found") || html.contains("Unable to locate story") { throw BabelError.notFound }
        if html.contains("Chapter not found") { throw BabelError.notFound }
        return try await Task.detached(priority: .userInitiated) {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            guard let text = try doc.select("#storytext").first() ?? doc.select("div.storytext").first() else {
                throw BabelError.parsing("Kapiteltext")
            }

            var titles: [String] = []
            if let select = try doc.select("select#chap_select").first() {
                titles = try select.select("option").array().map { opt in
                    let t = try opt.text()
                    if let m = t.firstMatch(#"^\d+\.\s*(.*)$"#) { return m[1] }
                    return t
                }
            }

            var meta = RemoteStory(source: .ffn, sourceID: storyID, title: "", url: chapterURL(storyID: storyID, number: 1))
            if let profile = try doc.select("#profile_top").first() {
                meta.title = try profile.select("b.xcontrast_txt").first()?.text() ?? ""
                if let a = try profile.select("a[href^=\"/u/\"]").first() {
                    meta.author = try a.text()
                    meta.authorURL = URL(string: try a.attr("href"), relativeTo: base)?.absoluteURL
                }
                meta.summary = try profile.select("div.xcontrast_txt").first()?.text() ?? ""
                if let img = try profile.select("img.cimage").first() {
                    let original = try img.attr("data-original")
                let src = try original.isEmpty ? img.attr("src") : original
                    if !src.isEmpty, !src.contains("/static/") { meta.coverURL = URL(string: src, relativeTo: base)?.absoluteURL }
                }
                if let metaEl = try profile.select("span.xgray").first() {
                    let dates = try metaEl.select("span[data-xutime]").array().compactMap { Double(try $0.attr("data-xutime")) }
                    applyMeta(try metaEl.text(), dates: dates, to: &meta)
                }
            }
            // Fandom aus der Brotkrumen-Navigation
            if let last = try doc.select("#pre_story_links a.xcontrast_txt").array().last {
                var fandom = try last.text()
                if fandom.hasSuffix(" Crossover") {
                    fandom = String(fandom.dropLast(" Crossover".count))
                    meta.fandoms = fandom.components(separatedBy: " + ").map(\.trimmed)
                } else {
                    meta.fandoms = [fandom]
                }
            }
            if !titles.isEmpty { meta.chapters = titles.count }

            let title = number - 1 < titles.count ? titles[number - 1] : (meta.title.isEmpty ? String(localized: "Kapitel \(number)") : meta.title)
            return (meta, titles, ChapterContent(title: title, html: try text.html()))
        }.value
    }
}
