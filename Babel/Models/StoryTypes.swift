import SwiftUI

/// Woher eine Geschichte kommt.
enum StorySource: String, Codable, CaseIterable, Sendable, Hashable {
    case ao3, ffn, gutenberg, epub

    var label: String {
        switch self {
        case .ao3: "Archive of Our Own"
        case .ffn: "FanFiction.net"
        case .gutenberg: "Project Gutenberg"
        case .epub: "Eigenes EPUB"
        }
    }

    var shortLabel: String {
        switch self {
        case .ao3: "AO3"
        case .ffn: "FFN"
        case .gutenberg: "Gutenberg"
        case .epub: "EPUB"
        }
    }

    var symbol: String {
        switch self {
        case .ao3: "archivebox.fill"
        case .ffn: "text.book.closed.fill"
        case .gutenberg: "building.columns.fill"
        case .epub: "doc.richtext.fill"
        }
    }

    var tint: Color {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .ao3: (0x9e1419, 0xff8a80)
        case .ffn: (0x33409e, 0x9fa8ff)
        case .gutenberg: (0x8c612e, 0xe0b27a)
        case .epub: (0x1a807a, 0x6fd6cc)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Geschichten, die online Kapitel nachladen (und Updates bekommen) können.
    var isWebFiction: Bool { self == .ao3 || self == .ffn }
}

enum ReadingStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case none, reading, planned, paused, finished, dropped

    var label: String {
        switch self {
        case .none: "Ohne Status"
        case .reading: "Lese ich"
        case .planned: "Später lesen"
        case .paused: "Pausiert"
        case .finished: "Gelesen"
        case .dropped: "Abgebrochen"
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
