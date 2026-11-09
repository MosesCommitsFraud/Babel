import Foundation
import SwiftSoup

/// 小説家になろう (syosetu.com): die größte japanische Plattform für Web Novels – Autor:innen veröffentlichen dort
/// selbst und kostenlos. Suche und Angaben kommen über die offizielle API (dev.syosetu.com), der Text von den
/// öffentlichen Kapitelseiten. Nur Japanisch.
enum SyosetuService {
    static let api = URL(string: "https://api.syosetu.com/novelapi/api/")!
    static let site = URL(string: "https://ncode.syosetu.com")!

    /// Ranglisten der API (`order`).
    enum List: String, CaseIterable, Identifiable, Sendable {
        case weekly = "weeklypoint", monthly = "monthlypoint", allTime = "hyoka", favorites = "favnovelcnt", new
        var id: String { rawValue }

        var label: String {
            switch self {
            case .weekly: String(localized: "Beliebt diese Woche")
            case .monthly: String(localized: "Beliebt diesen Monat")
            case .allTime: String(localized: "Am besten bewertet")
            case .favorites: String(localized: "Meiste Lesezeichen")
            case .new: String(localized: "Frisch aktualisiert")
            }
        }
    }

    private struct Novel: Decodable {
        var title: String?
        var ncode: String?
        var writer: String?
        var story: String?
        var keyword: String?
        var genre: Int?
        var general_firstup: String?
        var general_lastup: String?
        var novel_type: Int?
        var end: Int?
        var general_all_no: Int?
        var length: Int?
        var isr15: Int?
        var global_point: Int?
        var fav_novel_cnt: Int?
        var review_cnt: Int?
        var allcount: Int?
    }

    private static let pageSize = 20

    private static func query(_ items: [URLQueryItem]) async throws -> (novels: [Novel], total: Int) {
        var comps = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "out", value: "json")] + items
        let (data, http) = try await HTTPClient.shared.data(comps.url!, headers: ["Accept": "application/json"], minInterval: 1.0)
        guard http.statusCode == 200 else { throw BabelError.http(http.statusCode) }
        // Das erste Element nennt nur die Gesamtzahl.
        let all = try JSONDecoder().decode([Novel].self, from: data)
        return (Array(all.dropFirst()), all.first?.allcount ?? 0)
    }

    private static func page(_ items: [URLQueryItem], page: Int) async throws -> RoyalRoadService.Page {
        let start = (page - 1) * pageSize + 1
        // Die API liefert höchstens die ersten 2000 Treffer.
        guard start <= 2000 else { return .init(stories: [], hasNext: false) }
        let result = try await query(items + [URLQueryItem(name: "lim", value: String(pageSize)), URLQueryItem(name: "st", value: String(start))])
        let stories = result.novels.compactMap(story)
        return .init(stories: stories, hasNext: start + pageSize <= min(result.total, 2000) && !stories.isEmpty)
    }

    static func list(_ list: List, page: Int) async throws -> RoyalRoadService.Page {
        try await self.page([URLQueryItem(name: "order", value: list.rawValue)], page: page)
    }

    static func search(_ text: String, page: Int) async throws -> RoyalRoadService.Page {
        try await self.page([URLQueryItem(name: "word", value: text.trimmed), URLQueryItem(name: "order", value: "hyoka")], page: page)
    }

    /// Angaben eines Werks. `titles`: Kapiteltitel von der Inhaltsseite holen (mehrere Abrufe bei langen Werken) –
    /// für die Update-Prüfung reicht die Kapitelzahl der API.
    static func fiction(id: String, knownTitles: [String] = []) async throws -> RoyalRoadService.Fiction {
        let result = try await query([URLQueryItem(name: "ncode", value: id)])
        guard let novel = result.novels.first, var meta = story(novel) else { throw BabelError.notFound }
        let code = id.lowercased()
        // Kurzgeschichten haben keine Kapitelseiten: Der Text steht auf der Werkseite.
        if novel.novel_type == 2 {
            meta.chapters = 1
            return .init(meta: meta, titles: [meta.title], paths: ["/\(code)/"])
        }
        let count = max(novel.general_all_no ?? 1, 1)
        var titles = knownTitles
        if titles.count != count { titles = (try? await chapterTitles(code: code, count: count)) ?? [] }
        if titles.count != count { titles = (0..<count).map { i in i < titles.count ? titles[i] : "" } }
        return .init(meta: meta, titles: titles, paths: (1...count).map { "/\(code)/\($0)/" })
    }

    /// Kapiteltitel von der Inhaltsseite, 100 je Seite.
    private static func chapterTitles(code: String, count: Int) async throws -> [String] {
        var titles: [String] = []
        for page in 1...max(1, (count + 99) / 100) {
            var comps = URLComponents(url: site.appendingPathComponent(code + "/"), resolvingAgainstBaseURL: false)!
            if page > 1 { comps.queryItems = [URLQueryItem(name: "p", value: String(page))] }
            let (html, _, status) = try await HTTPClient.shared.html(comps.url!, minInterval: 1.0)
            guard status == 200 else { throw BabelError.http(status) }
            titles += try await Task.detached(priority: .userInitiated) { try parseContents(html) }.value
        }
        return titles
    }

    static func chapter(path: String, fallbackTitle: String) async throws -> ChapterContent {
        guard let url = URL(string: path, relativeTo: site)?.absoluteURL else { throw BabelError.notFound }
        let (html, _, status) = try await HTTPClient.shared.html(url, minInterval: 1.0)
        if status == 404 { throw BabelError.notFound }
        guard status == 200 else { throw BabelError.http(status) }
        return try await Task.detached(priority: .userInitiated) { try parseChapter(html, fallbackTitle: fallbackTitle) }.value
    }

    // MARK: Auswerten

    private static func story(_ n: Novel) -> RemoteStory? {
        guard let code = n.ncode, let title = n.title else { return nil }
        var s = RemoteStory(source: .syosetu, sourceID: code.lowercased(), title: title,
                            url: site.appendingPathComponent(code.lowercased() + "/"))
        s.author = n.writer ?? ""
        s.summary = (n.story ?? "").trimmed
        s.tags = (n.keyword ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        if let genre = n.genre, let name = genres[genre] { s.genres = [name] }
        s.categories = [n.novel_type == 2 ? String(localized: "Kurzgeschichte") : (n.end == 0 ? String(localized: "Abgeschlossen") : String(localized: "Laufend"))]
        s.rating = n.isr15 == 1 ? "R15" : ""
        s.language = "日本語"
        s.chapters = max(n.general_all_no ?? 1, 1)
        // `end`: 0 = Kurzgeschichte oder abgeschlossen, 1 = läuft noch.
        s.isComplete = n.end == 0
        // Japanisch zählt in Zeichen; als grobe Entsprechung gelten zwei Zeichen je Wort.
        s.words = n.length.map { $0 / 2 }
        s.favs = n.fav_novel_cnt
        s.reviews = n.review_cnt
        s.kudos = n.global_point
        s.published = n.general_firstup.flatMap { DateParsing.iso.date(from: String($0.prefix(10))) }
        s.updated = n.general_lastup.flatMap { DateParsing.iso.date(from: String($0.prefix(10))) }
        return s
    }

    /// Genres der API (Nummer → Name, wie auf der Website).
    static let genres: [Int: String] = [
        101: "異世界〔恋愛〕", 102: "現実世界〔恋愛〕", 201: "ハイファンタジー", 202: "ローファンタジー",
        301: "純文学", 302: "ヒューマンドラマ", 303: "歴史", 304: "推理", 305: "ホラー", 306: "アクション", 307: "コメディー",
        401: "VRゲーム", 402: "宇宙", 403: "空想科学", 404: "パニック",
        9901: "童話", 9902: "詩", 9903: "エッセイ", 9904: "リプレイ", 9999: "その他", 9801: "ノンジャンル",
    ]

    static func parseContents(_ html: String) throws -> [String] {
        try SwiftSoup.parse(html).select("div.p-eplist__sublist a.p-eplist__subtitle").array().map { try $0.text().trimmed }
    }

    static func parseChapter(_ html: String, fallbackTitle: String) throws -> ChapterContent {
        let doc = try SwiftSoup.parse(html, site.absoluteString)
        let blocks = try doc.select("div.p-novel__body div.p-novel__text").array()
        guard !blocks.isEmpty else { throw BabelError.parsing(String(localized: "Kapiteltext")) }
        // Illustrationen stehen mit Adressen ohne Protokoll („//…mitemin.net/…“) im Text – in der gespeicherten Datei
        // zeigten sie ins Leere. Der Link um das Bild führt nur zur Bildseite und entfällt.
        for image in try doc.select("div.p-novel__body img").array() {
            for attribute in ["src", "data-src"] {
                let value = try image.attr(attribute)
                if value.hasPrefix("//") { try image.attr(attribute, "https:" + value) }
            }
            if let link = image.parent(), link.tagName() == "a" { try link.unwrap() }
        }
        var body = ""
        for block in blocks {
            // Leerzeilen stehen als <p><br></p>: zu einem Abstand zusammenfassen, sonst klafft der Text auseinander.
            for p in try block.select("p").array() where try p.text().trimmed.isEmpty && p.select("img").isEmpty() {
                try p.attr("class", "babel-gap").html("")
            }
            let inner = try block.html()
            // Vor- und Nachwort der Autor:in sind eigene Blöcke.
            if block.hasClass("p-novel__text--preface") || block.hasClass("p-novel__text--afterword") {
                let end = block.hasClass("p-novel__text--afterword") ? " end" : ""
                body += "<aside class=\"babel-notes\(end)\"><div class=\"babel-notes-label\">\(String(localized: "Anmerkung"))</div>\(inner)</aside>"
            } else {
                body += inner
            }
        }
        let title = try doc.select("h1.p-novel__title").first()?.text().trimmed ?? ""
        // `lang` für den Reader: japanischer Satz (Zeilen dicht, kein Blocksatz, siehe `ReaderStyle`).
        return ChapterContent(title: title.isEmpty ? fallbackTitle : title, html: "<div lang=\"ja\">\(body)</div>")
    }
}
