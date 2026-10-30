import SwiftUI

/// Standard-Rating für neue Suchen auf AO3 und FFN (in den Einstellungen wählbar).
enum DefaultRating: String, CaseIterable, Identifiable {
    case all, kToT, kToKPlus, onlyT, mature
    static let key = "search.defaultRating"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: String(localized: "Alle Ratings")
        case .kToT: String(localized: "Bis T (K, K+, T)")
        case .kToKPlus: String(localized: "Bis K+ (jugendfrei)")
        case .onlyT: String(localized: "Nur T")
        case .mature: String(localized: "Nur M und Explicit")
        }
    }

    /// FFN-Parameter `r`.
    var ffnValue: String {
        switch self {
        case .all: "10"
        case .kToT: "103"
        case .kToKPlus: "102"
        case .onlyT: "3"
        case .mature: "4"
        }
    }

    /// AO3-Rating-IDs, die „muss“ sein sollen (G 10, T 11, M 12, E 13).
    var ao3Include: [Int] {
        switch self {
        case .all: []
        case .kToT: [10, 11]
        case .kToKPlus: [10]
        case .onlyT: [11]
        case .mature: [12, 13]
        }
    }

    static var current: DefaultRating {
        DefaultRating(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .all
    }
}

/// Standard-Sprache der Geschichten (unabhängig von der Sprache der App).
struct StoryLanguage: Identifiable, Hashable {
    let code: String      // ISO, wie AO3 es nutzt
    let name: String
    let ffnID: String?    // FFN-Parameter `lan`
    var id: String { code }

    static let key = "search.defaultLanguage"

    static let all: [StoryLanguage] = [
        .init(code: "", name: String(localized: "Alle Sprachen"), ffnID: nil),
        .init(code: "en", name: "English", ffnID: "1"),
        .init(code: "de", name: "Deutsch", ffnID: "4"),
        .init(code: "es", name: "Español", ffnID: "2"),
        .init(code: "fr", name: "Français", ffnID: "3"),
        .init(code: "it", name: "Italiano", ffnID: "11"),
        .init(code: "ptBR", name: "Português", ffnID: "8"),
        .init(code: "nl", name: "Nederlands", ffnID: "7"),
        .init(code: "pl", name: "Polski", ffnID: "13"),
        .init(code: "ru", name: "Русский", ffnID: "10"),
        .init(code: "sv", name: "Svenska", ffnID: "17"),
        .init(code: "fi", name: "Suomi", ffnID: "20"),
        .init(code: "da", name: "Dansk", ffnID: "19"),
        .init(code: "no", name: "Norsk", ffnID: "18"),
        .init(code: "cs", name: "Čeština", ffnID: "31"),
        .init(code: "hu", name: "Magyar", ffnID: "14"),
        .init(code: "tr", name: "Türkçe", ffnID: "30"),
        .init(code: "uk", name: "Українська", ffnID: "44"),
        .init(code: "vi", name: "Tiếng Việt", ffnID: "37"),
        .init(code: "id", name: "Bahasa Indonesia", ffnID: "32"),
        .init(code: "zh", name: "中文", ffnID: "5"),
        .init(code: "ja", name: "日本語", ffnID: "6"),
        .init(code: "ko", name: "한국어", ffnID: "36"),
    ]

    static var current: StoryLanguage {
        let code = UserDefaults.standard.string(forKey: key) ?? ""
        return all.first { $0.code == code } ?? all[0]
    }
}

extension AO3Filters {
    /// Neue, leere Suche mit den Standards aus den Einstellungen.
    static var withDefaults: AO3Filters {
        var f = AO3Filters()
        for id in DefaultRating.current.ao3Include { f.ratings[id] = .include }
        f.language = StoryLanguage.current.code
        return f
    }
}
