import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Erste Übereinstimmung eines regulären Ausdrucks; Index 0 = gesamter Treffer, danach Gruppen.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// Zahl aus Text wie "12,345" oder "1.234" ziehen.
    var digitsInt: Int? {
        let d = filter(\.isNumber)
        return d.isEmpty ? nil : Int(d)
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Stabiler Hash (z. B. für Cover-Farben), unabhängig vom Prozess.
    var stableHash: UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}

extension Int {
    var compact: String { formatted(.number.notation(.compactName)) }
    var grouped: String { formatted(.number) }
    /// Immer kurz, auch wo die Sprache keine Tausender-Abkürzung kennt (de: „12.345“): 873, 4k, 10k, 1,2M.
    /// Tausender werden abgerundet (4517 → 4k), wie man es grob liest.
    var short: String {
        switch self {
        case ..<1_000: "\(self)"
        case ..<1_000_000: "\(self / 1_000)k"
        default: (Double(self) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
        }
    }
}

enum BabelError: LocalizedError {
    case http(Int)
    case rateLimited
    case loginRequired
    case ffnLoginRequired
    /// Seite nicht erreichbar (Serverfehler, Cloudflare-Fehlerseite, Wartung).
    case siteDown(site: String, reason: String)
    case notFound
    case cloudflare
    case timeout
    case parsing(String)
    case invalidLink
    case unsupported(String)
    case epub(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): String(localized: "Der Server hat mit Fehler \(code) geantwortet.")
        case .rateLimited: String(localized: "Zu viele Anfragen – die Seite bremst gerade. Versuch es in einer Minute nochmal.")
        case .loginRequired: String(localized: "Dieses Werk ist nur für angemeldete AO3-Nutzer sichtbar. Melde dich in den Einstellungen bei AO3 an.")
        case .siteDown(let site, let reason): String(localized: "\(site) \(reason). Das liegt an der Seite, nicht an Babel – versuch es später nochmal.")
        case .ffnLoginRequired: String(localized: "Dafür musst du bei FanFiction.net angemeldet sein. Melde dich in den Einstellungen an.")
        case .notFound: String(localized: "Nicht gefunden – vielleicht wurde die Geschichte gelöscht.")
        case .cloudflare: String(localized: "Die Sicherheitsprüfung von FanFiction.net wurde nicht abgeschlossen. Versuch es nochmal.")
        case .timeout: String(localized: "Die Seite hat zu lange gebraucht.")
        case .parsing(let what): String(localized: "Die Seite konnte nicht gelesen werden (\(what)). Vielleicht hat sich ihr Aufbau geändert.")
        case .invalidLink: String(localized: "Das ist kein gültiger Link.")
        case .unsupported(let what): String(localized: "Dieser Link wird nicht unterstützt: \(what)")
        case .epub(let what): String(localized: "Das EPUB konnte nicht geöffnet werden: \(what)")
        }
    }
}

enum DateParsing {
    static let ao3Blurb: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy"
        return f
    }()

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Suchtreffer nach Titel sortieren: exakter Titel zuerst, dann Titel, die so anfangen,
/// dann Titel mit allen Wörtern, danach der Rest in der Reihenfolge der Seite.
/// (AO3 und FFN gewichten Titel kaum – exakte Titel landeten sonst weit hinten.)
enum TitleRanking {
    static func rank(_ stories: [RemoteStory], query: String) -> [RemoteStory] {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let q = norm(query)
        guard !q.isEmpty else { return stories }
        let words = q.split(separator: " ")
        func score(_ s: RemoteStory) -> Int {
            let t = norm(s.title)
            if t == q { return 0 }
            if t.hasPrefix(q) { return 1 }
            if words.allSatisfy({ t.contains($0) }) { return 2 }
            return 3
        }
        return stories.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
    }
}
