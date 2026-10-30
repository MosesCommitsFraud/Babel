import SwiftUI

/// Cover: echtes Bild (EPUB/Gutenberg/FFN) oder generiertes Farbcover mit Titel.
struct CoverView: View {
    let story: RemoteStory
    var localCover: URL? = nil
    var width: CGFloat = 56

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Group {
            if let localCover, let image = UIImage(contentsOfFile: localCover.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = coverURL {
                RemoteImage(url: url) { generated }
            } else {
                generated
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: width * 0.12))
        .overlay {
            RoundedRectangle(cornerRadius: width * 0.12).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: width * 0.06, y: width * 0.03)
    }

    /// FFN liefert in Listen nur 75 px – für große Cover die 180er-Variante nehmen.
    private var coverURL: URL? {
        guard let url = story.coverURL else { return nil }
        if story.source == .ffn, width > 60 {
            return URL(string: url.absoluteString.replacingOccurrences(of: "/75/", with: "/180/")) ?? url
        }
        return url
    }

    private var generated: some View {
        let seed = (story.fandoms.first ?? story.title).stableHash
        let hue = Double(seed % 360) / 360
        let top = Color(hue: hue, saturation: 0.55, brightness: 0.78)
        let bottom = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.42)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            if width >= 44 {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: story.source.symbol).font(.system(size: width * 0.16))
                    Text(story.title)
                        .font(.system(size: width * 0.13, weight: .bold, design: .serif))
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(width * 0.1)
            } else {
                Text(String(story.title.prefix(1)))
                    .font(.system(size: width * 0.5, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Kleine Inhalts-Markierung (bewusst kein Glas: Glas ist für Bedienelemente).
struct TagChip: View {
    let text: String
    var tint: Color? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint ?? .secondary)
        .background((tint ?? .secondary).opacity(0.13), in: .capsule)
    }
}

/// Filter-Chip mit Liquid Glass (Bedienelement).
struct GlassChip: View {
    @Environment(\.theme) private var theme
    let title: String
    var symbol: String? = nil
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? theme.primaryForeground : theme.foreground)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(theme.primary).interactive() : .regular.interactive(), in: .capsule)
    }
}

/// Zeilenumbrechendes Layout für Tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Eine Zeile für Suchergebnisse und Bibliothek.
struct StoryRow: View {
    @Environment(\.theme) private var theme
    let story: RemoteStory
    var localCover: URL? = nil
    var progress: Double? = nil
    var newChapters: Int = 0
    var status: ReadingStatus? = nil
    var showSummary = true
    /// Quelle (AO3/FFN …) nur dort zeigen, wo Quellen gemischt sind – nicht auf der jeweiligen Quellen-Seite.
    var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                CoverView(story: story, localCover: localCover, width: 54)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(story.title).font(.body.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 4)
                        if isNew {
                            Image(systemName: "leaf.fill")
                                .font(.footnote)
                                .foregroundStyle(Self.leafGreen)
                                .accessibilityLabel("Neue Geschichte")
                        }
                        if newChapters > 0 {
                            Text("+\(newChapters)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(theme.primaryForeground)
                                .background(theme.primary, in: .capsule)
                        }
                    }
                    Text(byline).font(.footnote).foregroundStyle(.secondary).lineLimit(1)

                    // Das Wichtigste als Chips: Rating, Status, Länge, Sprache.
                    HStack(spacing: 4) {
                        if showSource { TagChip(text: story.source.shortLabel, symbol: story.source.symbol) }
                        if !story.rating.isEmpty { TagChip(text: shortRating) }
                        TagChip(text: statusText, symbol: story.isComplete ? "checkmark" : nil)
                        if let w = story.words { TagChip(text: Self.wordsShort(w)).layoutPriority(-1) }
                        if !story.language.isEmpty { TagChip(text: languageShort).layoutPriority(-2) }
                    }
                    .lineLimit(1)

                    statsLine
                }
            }

            // Unter dem Cover über die ganze Breite: Pairing/Genre links, Daten rechts – dort ist Platz.
            if tagLine != nil || story.updated != nil || story.published != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let tags = tagLine {
                        Text(tags).font(.footnote.weight(.medium)).foregroundStyle(theme.primaryText).lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    dateLabel
                }
            }
            if showSummary, !story.summary.isEmpty {
                Text(story.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }

            if let progress, progress > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: progress).tint(theme.primary)
                    Text("\(Int(progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    static let leafGreen = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x7ED492) : UIColor(hex: 0x3E9A57) })
    static let heartRed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xFF6B6B) : UIColor(hex: 0xE0393E) })
    static let followYellow = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xFFD25E) : UIColor(hex: 0xE3A000) })

    /// Erst in den letzten 14 Tagen erschienen (bei AO3-Treffern ohne Veröffentlichungsdatum: ein Kapitel, frisch).
    private var isNew: Bool {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        if let p = story.published { return p > cutoff }
        return story.source == .ao3 && story.chapters == 1 && (story.updated ?? .distantPast) > cutoff
    }

    /// Veröffentlicht und (falls später) aktualisiert – Icon + Datum, ohne Kapsel.
    @ViewBuilder
    private var dateLabel: some View {
        let published = story.published
        let updated = story.updated
        let wasUpdated = updated.map { u in published.map { abs($0.timeIntervalSince(u)) > 60 } ?? true } ?? false
        HStack(spacing: 8) {
            if let published {
                datePill(published, symbol: "calendar", label: String(localized: "Veröffentlicht"))
            }
            if wasUpdated, let updated {
                datePill(updated, symbol: "arrow.clockwise", label: String(localized: "Aktualisiert"))
            }
        }
        .fixedSize()
    }

    private func datePill(_ date: Date, symbol: String, label: String) -> some View {
        // Im laufenden Jahr ohne Jahreszahl – spart Platz.
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let text = sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
        return Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) \(text)")
    }

    /// Bewertungen deutlich: ♥ rot, 🔔 gelb, Rest in der Akzentfarbe.
    private var statsLine: some View {
        HStack(spacing: 10) {
            ForEach(stats, id: \.symbol) { stat in
                HStack(spacing: 3) {
                    Image(systemName: stat.symbol + ".fill").foregroundStyle(statColor(stat.symbol))
                    Text(stat.value).foregroundStyle(.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(stat.value) \(stat.name)")
            }
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .lineLimit(1)
    }

    private func statColor(_ symbol: String) -> Color {
        switch symbol {
        case "heart": Self.heartRed
        case "bell": Self.followYellow
        default: theme.primary
        }
    }

    /// „Naruto U./Sakura H. · Romance/Adventure“ – Pairing zuerst, dann Genres.
    private var tagLine: String? {
        let parts = [story.relationships.first, story.genres.isEmpty ? nil : story.genres.joined(separator: "/")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var byline: String {
        var parts = [story.author]
        if let f = story.fandoms.first { parts.append(story.fandoms.count > 1 ? "\(f) +\(story.fandoms.count - 1)" : f) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Wie die Geschichte ankommt: FFN Favs/Follows/Reviews, AO3 Kudos/Aufrufe/Lesezeichen, Gutenberg Downloads.
    private var stats: [(symbol: String, value: String, name: String)] {
        var list: [(String, String, String)] = []
        func add(_ symbol: String, _ value: Int?, _ name: String) {
            if let value, value > 0 { list.append((symbol, value.formatted(.number.notation(.compactName)), name)) }
        }
        switch story.source {
        case .ffn:
            add("heart", story.favs, String(localized: "Favoriten"))
            add("bell", story.follows, String(localized: "Follows"))
            add("text.bubble", story.reviews, String(localized: "Reviews"))
        case .ao3:
            add("heart", story.kudos, String(localized: "Kudos"))
            add("eye", story.hits, String(localized: "Aufrufe"))
            add("bookmark", story.bookmarks, String(localized: "Lesezeichen"))
        case .gutenberg, .standardEbooks, .archive:
            add("arrow.down.circle", story.hits, String(localized: "Downloads"))
        case .epub:
            break
        }
        return list.map { (symbol: $0.0, value: $0.1, name: $0.2) }
    }

    static func wordsShort(_ w: Int) -> String {
        if w >= 1_000_000 { return "\((Double(w) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mio. Wörter" }
        if w >= 1_000 { return String(localized: "\(w / 1_000)k Wörter") }
        return String(localized: "\(w) Wörter")
    }

    /// „Fertig · 12 Kap.“ bzw. „3/? Kap.“ – Status und Länge in einem Chip.
    private var statusText: String {
        if !story.source.isWebFiction { return String(localized: "Buch") }
        if story.isComplete { return "Fertig · \(story.chapters) Kap." }
        return chapterText
    }

    private var languageShort: String {
        let map = ["English": "EN", "Deutsch": "DE", "German": "DE", "Español": "ES", "Spanish": "ES", "Français": "FR",
                   "French": "FR", "Italiano": "IT", "Italian": "IT", "Português": "PT", "Portuguese": "PT",
                   "Русский": "RU", "Russian": "RU", "中文-普通话 國語": "ZH", "Chinese": "ZH", "日本語": "JA", "Japanese": "JA",
                   "Polski": "PL", "Polish": "PL", "Nederlands": "NL", "Dutch": "NL", "Tiếng Việt": "VI", "Vietnamese": "VI",
                   "Indonesian": "ID", "Bahasa Indonesia": "ID", "Türkçe": "TR", "Turkish": "TR", "한국어": "KO", "Korean": "KO"]
        if let short = map[story.language] { return short }
        return story.language.count <= 3 ? story.language.uppercased() : String(story.language.prefix(10))
    }

    private var chapterText: String {
        if !story.source.isWebFiction { return String(localized: "Buch") }
        if let total = story.totalChapters, total != story.chapters { return "\(story.chapters)/\(total) Kap." }
        if !story.isComplete, story.source == .ao3 { return "\(story.chapters)/? Kap." }
        return "\(story.chapters) Kap."
    }

    private var shortRating: String {
        if let r = AO3Service.ratings.first(where: { $0.name == story.rating }) { return r.short }
        return story.rating
    }
}

/// Fehleranzeige mit "Nochmal".
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Nochmal versuchen", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.glass)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding()
    }
}

/// Dreifach-Schalter für Filter: egal / muss (grün) / ausschließen (rot) – als Liquid Glass.
/// Die Auswahl ist eine eingefärbte Glaskapsel, die beim Wechsel zwischen den Feldern fließt.
struct TriStateControl: View {
    @Environment(\.theme) private var theme
    @Binding var state: TriState
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                segment(.any, "circle.dashed", .secondary)
                segment(.include, "checkmark", theme.include)
                segment(.exclude, "xmark", theme.exclude)
            }
        }
    }

    private func segment(_ value: TriState, _ symbol: String, _ color: Color) -> some View {
        let selected = state == value
        return Button {
            withAnimation(.bouncy(duration: 0.3)) { state = value }
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(selected ? (value == .any ? theme.foreground : .white) : color)
                .frame(width: 38, height: 30)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(value == .any ? Color.gray.opacity(0.45) : color).interactive() : .regular.interactive(),
                     in: .capsule)
        .glassEffectID(value, in: glass)
        .accessibilityLabel(value == .any ? "egal" : value == .include ? "muss" : String(localized: "ausschließen"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Wenige Auswahlmöglichkeiten als Glaskapseln nebeneinander (fließende Auswahl).
struct GlassSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.theme) private var theme
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(options, id: \.value) { option in
                    let selected = option.value == selection
                    Button {
                        withAnimation(.bouncy(duration: 0.3)) { selection = option.value }
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(selected ? theme.primaryForeground : .primary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? .regular.tint(theme.primary).interactive() : .regular.interactive(), in: .capsule)
                    .glassEffectID(option.value, in: glass)
                }
            }
        }
    }
}

/// Banner, wenn eine Seite gerade bremst (HTTP 429).
struct RateLimitBanner: View {
    @State private var status = RateLimitStatus.shared

    var body: some View {
        if let until = status.until, status.host != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                Label("\(status.siteName) bremst gerade – weiter in \(seconds) s", systemImage: "tortoise.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Ladeanzeige, die nach ein paar Sekunden erklärt, warum es dauert.
struct SlowLoadingView: View {
    let text: String
    let slowHint: String
    @State private var isSlow = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(text)
            if isSlow {
                Text(slowHint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 40)
        .task {
            try? await Task.sleep(for: .seconds(6))
            withAnimation { isSlow = true }
        }
    }
}
