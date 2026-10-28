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
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(tint ?? .primary)
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(story: story, localCover: localCover, width: 58)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(story.title).font(.headline).lineLimit(2)
                    Spacer(minLength: 4)
                    if newChapters > 0 {
                        Text("+\(newChapters)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(theme.primaryForeground)
                            .background(theme.primary, in: .capsule)
                    }
                }
                Text(byline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)

                // Zwei feste Zeilen mit den wichtigsten Angaben – was nicht passt, wird gekürzt statt umgebrochen.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        TagChip(text: story.source.shortLabel, tint: story.source.tint, symbol: story.source.symbol)
                        if !story.rating.isEmpty { TagChip(text: shortRating, tint: ratingTint) }
                        TagChip(text: statusText, tint: story.isComplete ? theme.include : nil,
                                symbol: story.isComplete ? "checkmark" : nil)
                        if let w = story.words { TagChip(text: Self.wordsShort(w)).layoutPriority(-1) }
                    }
                    HStack(spacing: 5) {
                        if let d = story.updated {
                            TagChip(text: d.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits)), symbol: "clock")
                        }
                        if !story.language.isEmpty { TagChip(text: languageShort, symbol: "globe") }
                        if let pairing = story.relationships.first {
                            TagChip(text: pairing, tint: .pink).layoutPriority(-1)
                        } else if !story.genres.isEmpty {
                            TagChip(text: story.genres.joined(separator: "/")).layoutPriority(-1)
                        }
                    }
                }
                .lineLimit(1)

                if showSummary, !story.summary.isEmpty {
                    Text(story.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }

                if let progress, progress > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: progress).tint(theme.primary)
                        Text("\(Int(progress * 100)) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var byline: String {
        var parts = [story.author]
        if let f = story.fandoms.first { parts.append(story.fandoms.count > 1 ? "\(f) +\(story.fandoms.count - 1)" : f) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var ratingTint: Color? {
        switch shortRating {
        case "E", "M": theme.exclude
        case "T", "K+": .orange
        case "G", "K": theme.include
        default: nil
        }
    }

    static func wordsShort(_ w: Int) -> String {
        if w >= 1_000_000 { return "\((Double(w) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mio. Wörter" }
        if w >= 1_000 { return "\(w / 1_000)k Wörter" }
        return "\(w) Wörter"
    }

    /// „Fertig · 12 Kap.“ bzw. „3/? Kap.“ – Status und Länge in einem Chip.
    private var statusText: String {
        if story.source == .epub || story.source == .gutenberg { return "Buch" }
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
        if story.source == .epub || story.source == .gutenberg { return "Buch" }
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
        .accessibilityLabel(value == .any ? "egal" : value == .include ? "muss" : "ausschließen")
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
                            .minimumScaleFactor(0.8)
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
