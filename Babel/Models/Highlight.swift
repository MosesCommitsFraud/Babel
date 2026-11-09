import Foundation
import SwiftData

/// Eine markierte Textstelle, auf Wunsch mit Notiz. Wird wie die Bibliothek über iCloud synchronisiert
/// (alle Felder mit Standardwert, kein `.unique`). Gehört über `storyKey` zur Geschichte – ohne Beziehung,
/// damit das Zusammenführen doppelter Zeilen (`CloudSync`) nichts umhängen muss.
@Model
final class Highlight {
    #Index<Highlight>([\.storyKey])

    var syncID: String = UUID().uuidString
    var storyKey: String = ""
    var chapter: Int = 0
    /// Absatz wie beim Vorlesen und bei der Lesestelle gezählt (`babelBlocks`).
    var paragraph: Int = 0
    /// Zeichen im Text des Absatzes, `end` ausschließlich.
    var start: Int = 0
    var end: Int = 0
    var text: String = ""
    var note: String = ""
    var createdAt: Date = Date()

    init(storyKey: String, chapter: Int, paragraph: Int, start: Int, end: Int, text: String) {
        self.storyKey = storyKey
        self.chapter = chapter
        self.paragraph = paragraph
        self.start = start
        self.end = end
        self.text = text
        self.createdAt = Date()
    }
}

/// Markierungen sind standardmäßig aus – wer sie will, schaltet sie in den Einstellungen ein.
enum HighlightSettings {
    static let key = "reader.highlights"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func all(for storyKey: String, in context: ModelContext?) -> [Highlight] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<Highlight>(predicate: #Predicate { $0.storyKey == storyKey },
                                                    sortBy: [SortDescriptor(\.chapter), SortDescriptor(\.paragraph), SortDescriptor(\.start)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Mit der Geschichte verschwinden auch ihre Markierungen.
    static func deleteAll(for storyKey: String, in context: ModelContext) {
        for highlight in all(for: storyKey, in: context) { context.delete(highlight) }
    }
}
