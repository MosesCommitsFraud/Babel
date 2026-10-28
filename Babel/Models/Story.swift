import Foundation
import SwiftData

@Model
final class Story {
    @Attribute(.unique) var key: String = ""
    var sourceRaw: String = StorySource.epub.rawValue
    var sourceID: String = ""

    // Metadaten
    var title: String = ""
    var author: String = ""
    var authorURLString: String? = nil
    var summary: String = ""
    var fandoms: [String] = []
    var relationships: [String] = []
    var characters: [String] = []
    var tags: [String] = []
    var warnings: [String] = []
    var categories: [String] = []
    var genres: [String] = []
    var rating: String = ""
    var language: String = ""
    var words: Int? = nil
    var chapterCount: Int = 1
    var totalChapters: Int? = nil
    var isComplete: Bool = false
    /// Nicht `updated` nennen: kollidiert mit `isUpdated` von Core Data (KVC-Schlüssel „updated“) und liefert dann immer 2001-01-01.
    var lastUpdated: Date? = nil
    var published: Date? = nil
    var kudos: Int? = nil
    var hits: Int? = nil
    var comments: Int? = nil
    var bookmarks: Int? = nil
    var reviews: Int? = nil
    var favs: Int? = nil
    var follows: Int? = nil
    var urlString: String = ""
    var coverURLString: String? = nil
    var downloadURLString: String? = nil

    // Lokaler Zustand
    var folderName: String = ""
    var inLibrary: Bool = false
    var addedAt: Date? = nil
    var lastOpenedAt: Date? = nil
    /// Wann die Storyseite zuletzt angesehen wurde (für den Verlauf in der Bibliothek).
    var viewedAt: Date? = nil
    var statusRaw: String = ReadingStatus.none.rawValue
    var isFavorite: Bool = false
    var currentChapter: Int = 0
    var chapterProgress: Double = 0
    var chapterTitles: [String] = []
    var spinePaths: [String] = []
    var coverPath: String? = nil
    var newChapters: Int = 0
    var downloadedCount: Int = 0
    var lastCheckedAt: Date? = nil
    var personalNote: String = ""

    @Relationship(deleteRule: .nullify, inverse: \Shelf.stories)
    var shelves: [Shelf] = []

    init(remote: RemoteStory) {
        self.key = remote.key
        self.sourceRaw = remote.source.rawValue
        self.sourceID = remote.sourceID
        self.folderName = remote.key
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        apply(remote: remote)
    }

    var source: StorySource { StorySource(rawValue: sourceRaw) ?? .epub }

    var status: ReadingStatus {
        get { ReadingStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }

    var url: URL? { URL(string: urlString) }
    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    /// Anzahl der Kapitel, die dieser Reader kennt.
    var knownChapterCount: Int {
        max(chapterCount, chapterTitles.count, spinePaths.count, 1)
    }

    /// Gesamtfortschritt 0…1 über alle Kapitel.
    var overallProgress: Double {
        let n = Double(knownChapterCount)
        return min(1, max(0, (Double(currentChapter) + chapterProgress) / n))
    }

    var hasStarted: Bool { lastOpenedAt != nil }

    func title(ofChapter index: Int) -> String {
        if index < chapterTitles.count, !chapterTitles[index].isEmpty { return chapterTitles[index] }
        return String(localized: "Kapitel \(index + 1)")
    }

    /// Übernimmt Metadaten. Leere Felder überschreiben keine vorhandenen Werte.
    func apply(remote r: RemoteStory) {
        func set(_ value: String, _ target: inout String) { if !value.isEmpty { target = value } }
        func setList(_ value: [String], _ target: inout [String]) { if !value.isEmpty { target = value } }

        set(r.title, &title)
        set(r.author, &author)
        if let a = r.authorURL { authorURLString = a.absoluteString }
        set(r.summary, &summary)
        setList(r.fandoms, &fandoms)
        setList(r.relationships, &relationships)
        setList(r.characters, &characters)
        setList(r.tags, &tags)
        setList(r.warnings, &warnings)
        setList(r.categories, &categories)
        setList(r.genres, &genres)
        set(r.rating, &rating)
        set(r.language, &language)
        words = r.words ?? words
        if r.chapters > 0 { chapterCount = max(r.chapters, chapterTitles.count) }
        totalChapters = r.totalChapters
        isComplete = r.isComplete
        lastUpdated = r.updated ?? lastUpdated
        published = r.published ?? published
        kudos = r.kudos ?? kudos
        hits = r.hits ?? hits
        comments = r.comments ?? comments
        bookmarks = r.bookmarks ?? bookmarks
        reviews = r.reviews ?? reviews
        favs = r.favs ?? favs
        follows = r.follows ?? follows
        urlString = r.url.absoluteString
        if let c = r.coverURL { coverURLString = c.absoluteString }
        if let d = r.downloadURL { downloadURLString = d.absoluteString }
    }

    /// Für die Anzeige in Listen wird dieselbe Struktur wie bei Suchergebnissen benutzt.
    var asRemote: RemoteStory {
        RemoteStory(
            source: source, sourceID: sourceID, title: title, author: author,
            authorURL: authorURLString.flatMap(URL.init(string:)), summary: summary,
            fandoms: fandoms, relationships: relationships, characters: characters,
            tags: tags, warnings: warnings, categories: categories, genres: genres,
            rating: rating, language: language, words: words, chapters: knownChapterCount,
            totalChapters: totalChapters, isComplete: isComplete, updated: lastUpdated,
            published: published, kudos: kudos, hits: hits, comments: comments,
            bookmarks: bookmarks, reviews: reviews, favs: favs, follows: follows,
            url: url ?? URL(string: "about:blank")!, coverURL: coverURL,
            downloadURL: downloadURLString.flatMap(URL.init(string:))
        )
    }
}

@Model
final class Shelf {
    var name: String = ""
    var symbol: String = "folder.fill"
    var createdAt: Date = Date()
    var stories: [Story] = []

    init(name: String, symbol: String = "folder.fill") {
        self.name = name
        self.symbol = symbol
        self.createdAt = Date()
    }
}
