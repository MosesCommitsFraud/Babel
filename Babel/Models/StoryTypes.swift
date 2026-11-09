import SwiftUI

/// Woher eine Geschichte kommt.
enum StorySource: String, Codable, CaseIterable, Sendable, Hashable {
    case ao3, ffn, royalRoad, syosetu, gutenberg, standardEbooks, archive, opds, epub

    var label: String {
        switch self {
        case .ao3: String(localized: "Archive of Our Own")
        case .ffn: String(localized: "FanFiction.net")
        case .royalRoad: "Royal Road"
        case .syosetu: "小説家になろう"
        case .opds: String(localized: "Katalog")
        case .gutenberg: String(localized: "Project Gutenberg")
        case .standardEbooks: String(localized: "Standard Ebooks")
        case .archive: String(localized: "Internet Archive")
        case .epub: String(localized: "Eigenes EPUB")
        }
    }

    var shortLabel: String {
        switch self {
        case .ao3: "AO3"
        case .ffn: "FFN"
        case .royalRoad: "Royal Road"
        case .syosetu: "Syosetu"
        case .opds: String(localized: "Katalog")
        case .gutenberg: "Gutenberg"
        case .standardEbooks: "Standard"
        case .archive: "Archive"
        case .epub: "EPUB"
        }
    }

    var symbol: String {
        switch self {
        case .ao3: "archivebox.fill"
        case .ffn: "text.book.closed.fill"
        case .royalRoad: "crown.fill"
        case .syosetu: "character.book.closed.fill.ja"
        case .opds: "square.stack.3d.up.fill"
        case .gutenberg: "building.columns.fill"
        case .standardEbooks: "book.pages.fill"
        case .archive: "archivebox.circle.fill"
        case .epub: "doc.richtext.fill"
        }
    }

    var tint: Color {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .ao3: (0x9e1419, 0xff8a80)
        case .ffn: (0x33409e, 0x9fa8ff)
        case .royalRoad: (0x8a5a1e, 0xe2b877)
        case .syosetu: (0x2f7f8f, 0x8fd0dc)
        case .opds: (0x4b6a58, 0x9fc4ad)
        case .gutenberg: (0x8c612e, 0xe0b27a)
        case .standardEbooks: (0x8a6d3b, 0xd8bb85)
        case .archive: (0x52606d, 0xaab6c2)
        case .epub: (0x1a807a, 0x6fd6cc)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Geschichten, die online Kapitel nachladen (und Updates bekommen) können.
    var isWebFiction: Bool { self == .ao3 || self == .ffn || isSerial }

    /// Web-Serien aus dem Bücher-Tab: Werkseite kennt alle Kapitel, jedes Kapitel ist eine eigene Seite (Adressen in `spinePaths`).
    var isSerial: Bool { self == .royalRoad || self == .syosetu }

    /// Freie Bücher aus Online-Bibliotheken (werden als EPUB geladen).
    var isOnlineBook: Bool { self == .gutenberg || self == .standardEbooks || self == .archive || self == .opds }

    /// Kommentare/Reviews und Autorenseiten gibt es in der App nur für AO3 und FanFiction.net.
    var hasCommunityPages: Bool { self == .ao3 || self == .ffn }
}

enum ReadingStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case none, reading, planned, paused, finished, dropped

    var label: String {
        switch self {
        case .none: String(localized: "Ohne Status")
        case .reading: String(localized: "Lese ich")
        case .planned: String(localized: "Später lesen")
        case .paused: String(localized: "Pausiert")
        case .finished: String(localized: "Gelesen")
        case .dropped: String(localized: "Abgebrochen")
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .reading: "book.fill"
        case .planned: "bookmark.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .dropped: "xmark.circle.fill"
        }
    }
}

/// Zugehörigkeit zu einer Serie (AO3): welche Serie und der wievielte Teil.
struct SeriesRef: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var position: Int? = nil
}

/// Einheitliche Metadaten für Suchergebnisse aus allen Quellen.
struct RemoteStory: Identifiable, Hashable, Codable, Sendable {
    var source: StorySource
    var sourceID: String
    var title: String
    var author: String = ""
    var authorURL: URL? = nil
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
    var chapters: Int = 1
    /// Nur Titel/Autor:in aus einer Linkliste (z. B. FFN-Follows) – Kapitel und Status sind dann unbekannt,
    /// nicht „1 Kapitel, unfertig“. Darf vorhandene Angaben nicht überschreiben.
    var isLinkOnly: Bool { source.isWebFiction && words == nil && rating.isEmpty && summary.isEmpty }
    var totalChapters: Int? = nil
    var isComplete: Bool = false
    var updated: Date? = nil
    var published: Date? = nil
    var kudos: Int? = nil
    var hits: Int? = nil
    var comments: Int? = nil
    var bookmarks: Int? = nil
    var reviews: Int? = nil
    var favs: Int? = nil
    var follows: Int? = nil
    var url: URL
    var coverURL: URL? = nil
    var downloadURL: URL? = nil
    /// Optional, damit ältere gespeicherte Einträge (ohne das Feld) weiter laden.
    var series: SeriesRef? = nil

    var key: String { "\(source.rawValue):\(sourceID)" }
    var id: String { key }
}

struct ChapterContent: Sendable {
    var title: String
    var html: String
}

/// Profil einer Autorin / eines Autors (AO3 oder FFN).
struct AuthorProfile: Sendable {
    var name: String
    var joined: Date? = nil
    var bio: String = ""
    var storyCount: Int? = nil
    var favoriteCount: Int? = nil
    var url: URL
    /// FFN liefert alles auf einer Seite; AO3 lädt seitenweise nach.
    var stories: [RemoteStory] = []
    var favorites: [RemoteStory] = []
}
