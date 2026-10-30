import SwiftUI
import SwiftData

struct StoryDetailView: View {
    @Bindable var story: Story
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @Environment(ReaderPresenter.self) private var reader
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.readerJump) private var readerJump
    @Query(sort: \Shelf.createdAt) private var shelves: [Shelf]

    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var downloadedCount = 0
    @State private var exportedFile: URL?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                if !ratingItems.isEmpty { ratingBar }
                if story.inLibrary { organize }
                stats
                if !story.summary.isEmpty { summary }
                tagSections
                if story.source.isWebFiction { commentsLink }
                chapters
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            story.viewedAt = .now
            try? context.save()
            await library.enrichGutenberg(story)
            await library.refreshMetadataIfSparse(story)
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file]).ignoresSafeArea()
        }
        .alert("Fehler", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
        .task(id: story.downloadedCount) { downloadedCount = ContentStore.countDownloaded(story) }
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(story: story.asRemote, localCover: ContentStore.coverFileURL(story), width: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(story.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if !story.author.isEmpty {
                    if let authorURL = story.authorURLString.flatMap(URL.init(string:)), story.source.isWebFiction {
                        NavigationLink {
                            AuthorView(source: story.source, name: story.author, url: authorURL)
                        } label: {
                            HStack(spacing: 4) {
                                Text(story.author).font(.headline)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(theme.primaryText)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(story.author).font(.headline).foregroundStyle(.secondary)
                    }
                }
                TagChip(text: story.source.label, symbol: story.source.symbol)
                if story.newChapters > 0 {
                    Label(story.newChapters == 1 ? String(localized: "1 neues Kapitel") : String(localized: "\(story.newChapters) neue Kapitel"), systemImage: "sparkles")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if story.hasStarted {
                    ProgressView(value: story.overallProgress) {
                        Text("\(Int(story.overallProgress * 100)) % gelesen").font(.caption).foregroundStyle(.secondary)
                    }
                    .tint(theme.primary)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Aktionen (Liquid Glass)

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    open(at: nil)
                } label: {
                    Label(story.hasStarted ? String(localized: "Weiterlesen") : String(localized: "Lesen"), systemImage: "book.fill")
                        .foregroundStyle(theme.primaryForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.primary)

                Button {
                    if story.inLibrary { library.removeFromLibrary(story, context: context) }
                    else { library.addToLibrary(story, context: context) }
                } label: {
                    Image(systemName: story.inLibrary ? "checkmark" : "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(story.inLibrary ? String(localized: "Aus Bibliothek entfernen") : String(localized: "Zur Bibliothek hinzufügen"))

                if story.source.isWebFiction || story.spinePaths.isEmpty {
                    Button {
                        Task { await downloadAll() }
                    } label: {
                        if let p = library.downloads[story.key] {
                            ProgressView(value: p).progressViewStyle(.circular).frame(width: 22, height: 22)
                        } else {
                            Image(systemName: isFullyDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .frame(width: 22, height: 22)
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(library.downloads[story.key] != nil)
                    .accessibilityLabel("Offline speichern")
                }

                Button {
                    story.isFavorite.toggle()
                    try? context.save()
                } label: {
                    Image(systemName: story.isFavorite ? "heart.fill" : "heart")
                        .frame(width: 22, height: 22)
                        .foregroundStyle(story.isFavorite ? .pink : .primary)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Favorit")
            }
        }
        .controlSize(.regular)
    }

    private var isFullyDownloaded: Bool {
        downloadedCount >= story.knownChapterCount && downloadedCount > 0
    }

    private var organize: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Status", selection: $story.status) {
                    ForEach(ReadingStatus.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
            } label: {
                Label(story.status.label, systemImage: story.status.symbol)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .glassEffect(.regular.interactive(), in: .capsule)

            Menu {
                if shelves.isEmpty { Text("Lege Sammlungen in der Bibliothek über „+“ an.") }
                ForEach(shelves) { shelf in
                    Toggle(shelf.name, isOn: Binding(
                        get: { story.shelves.contains { $0.persistentModelID == shelf.persistentModelID } },
                        set: { on in
                            if on { story.shelves.append(shelf) }
                            else { story.shelves.removeAll { $0.persistentModelID == shelf.persistentModelID } }
                            try? context.save()
                        }
                    ))
                }
            } label: {
                Label(story.shelves.isEmpty ? String(localized: "Sammlung") : story.shelves.map(\.name).joined(separator: ", "),
                      systemImage: "folder")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Inhalt

    private struct StatItem: Identifiable {
        let label: String
        let value: String
        let symbol: String
        var id: String { label }
    }

    private var statItems: [StatItem] {
        var items: [StatItem] = []
        func add(_ label: String, _ value: String?, _ symbol: String) {
            if let value, !value.isEmpty { items.append(StatItem(label: label, value: value, symbol: symbol)) }
        }
        add(String(localized: "Wörter"), story.words?.grouped, "textformat.size")
        add(String(localized: "Kapitel"), chapterLabel, "list.number")
        if story.source.isOnlineBook { add(String(localized: "Downloads"), story.hits?.compact, "arrow.down.circle") }
        add(String(localized: "Aktualisiert"), story.lastUpdated?.formatted(date: .abbreviated, time: .omitted), "clock")
        add(String(localized: "Veröffentlicht"), story.published?.formatted(date: .abbreviated, time: .omitted), "calendar")
        add(String(localized: "Sprache"), story.language, "globe")
        add(String(localized: "Rating"), story.rating, "exclamationmark.shield")
        return items
    }

    // MARK: - Bewertungen (gut sichtbar direkt unter dem Kopf)

    private struct RatingItem: Identifiable {
        let label: String
        let value: Int
        let symbol: String
        let color: Color
        var opensComments = false
        var id: String { label }
    }

    private var commentCount: Int? { story.source == .ffn ? story.reviews : story.comments }
    private var commentsTitle: String { story.source == .ffn ? String(localized: "Reviews") : String(localized: "Kommentare") }

    private var ratingItems: [RatingItem] {
        var items: [RatingItem] = []
        func add(_ label: String, _ value: Int?, _ symbol: String, _ color: Color, comments: Bool = false) {
            if let value, value > 0 { items.append(RatingItem(label: label, value: value, symbol: symbol, color: color, opensComments: comments)) }
        }
        switch story.source {
        case .ffn:
            add(String(localized: "Favs"), story.favs, "heart.fill", StoryRow.heartRed)
            add(String(localized: "Follows"), story.follows, "bell.fill", StoryRow.followYellow)
            add(String(localized: "Reviews"), story.reviews, "text.bubble.fill", theme.primary, comments: true)
        case .ao3:
            add(String(localized: "Kudos"), story.kudos, "heart.fill", StoryRow.heartRed)
            add(String(localized: "Lesezeichen"), story.bookmarks, "bookmark.fill", StoryRow.followYellow)
            add(String(localized: "Kommentare"), story.comments, "text.bubble.fill", theme.primary, comments: true)
            add(String(localized: "Aufrufe"), story.hits, "eye.fill", .secondary)
        default:
            break
        }
        return items
    }

    /// Wie die Kennzahlen im App Store: große Zahlen, farbige Symbole, durch Linien getrennt – ohne Karten.
    private var ratingBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(ratingItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().frame(height: 44)
                }
                let column = VStack(spacing: 4) {
                    Image(systemName: item.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.color)
                        .frame(width: 30, height: 30)
                        .background(item.color.opacity(0.15), in: .circle)
                    Text(item.value.formatted(.number.notation(.compactName)))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .fontDesign(.rounded)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 2) {
                        Text(item.label)
                        if item.opensComments { Image(systemName: "chevron.right").font(.caption2.weight(.bold)) }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.opensComments ? AnyShapeStyle(theme.primaryText) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)

                if item.opensComments {
                    NavigationLink { CommentsView(story: story) } label: { column }
                        .buttonStyle(.plain)
                } else {
                    column
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var commentsLink: some View {
        NavigationLink {
            CommentsView(story: story)
        } label: {
            HStack {
                Label(commentsTitle, systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                if let n = commentCount { Text(n.grouped).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(theme.card, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(statItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Label(item.label, systemImage: item.symbol).font(.caption).foregroundStyle(.secondary)
                    Text(item.value).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.card, in: .rect(cornerRadius: 14))
            }
        }
    }

    private var chapterLabel: String {
        if !story.source.isWebFiction {
            return story.spinePaths.isEmpty ? "–" : "\(story.spinePaths.count)"
        }
        if let total = story.totalChapters { return "\(story.knownChapterCount)/\(total)" }
        return story.isComplete ? "\(story.knownChapterCount) ✓" : "\(story.knownChapterCount)/?"
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zusammenfassung").font(.headline)
            Text(story.summary).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var tagSections: some View {
        tagSection("Fandoms", story.fandoms)
        tagSection("Warnungen", story.warnings)
        tagSection("Kategorien", story.categories)
        tagSection("Genres", story.genres)
        tagSection("Beziehungen", story.relationships)
        tagSection("Charaktere", story.characters)
        tagSection(story.source.isOnlineBook ? "Themen" : "Tags", story.tags)
    }

    @ViewBuilder
    private func tagSection(_ title: String, _ tags: [String], tint: Color? = nil) -> some View {
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        if story.source == .ao3 {
                            NavigationLink {
                                AO3SearchView(initialFilters: AO3Filters(otherTags: [tag]), title: tag)
                            } label: {
                                TagChip(text: tag, tint: tint)
                            }
                            .buttonStyle(.plain)
                        } else {
                            TagChip(text: tag, tint: tint)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chapters: some View {
        let count = story.chapterTitles.isEmpty ? (story.source.isWebFiction ? story.knownChapterCount : 0) : story.chapterTitles.count
        if count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Kapitel").font(.headline)
                    Spacer()
                    Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                // Alle Kapitel direkt zeigen – kein „Mehr anzeigen“.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        Button { open(at: i) } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                                Text(story.title(ofChapter: i)).lineLimit(1)
                                Spacer()
                                if i == story.currentChapter && story.hasStarted {
                                    Image(systemName: "bookmark.fill").foregroundStyle(theme.primary)
                                } else if story.source.isWebFiction && !ContentStore.hasChapter(story, i) {
                                    Image(systemName: "icloud").foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let url = story.url, url.scheme?.hasPrefix("http") == true {
                ShareLink(item: url)
            }
            Menu {
                if let url = story.url, url.scheme?.hasPrefix("http") == true {
                    Button("Im Browser öffnen", systemImage: "safari") { openURL(url) }
                }
                if story.source.isWebFiction {
                    Button(isExporting ? "EPUB wird erstellt …" : "Als EPUB exportieren", systemImage: "square.and.arrow.up.on.square") {
                        Task { await exportEPUB() }
                    }
                    .disabled(isExporting)
                    Button("Nach neuen Kapiteln suchen", systemImage: "arrow.clockwise") {
                        Task { await checkUpdates() }
                    }
                    Button("Offline-Kopie löschen", systemImage: "icloud.slash") {
                        library.deleteOfflineContent(story, context: context)
                        downloadedCount = 0
                    }
                }
                Divider()
                Button("Vollständig löschen", systemImage: "trash", role: .destructive) {
                    let target = story
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        library.delete(target, context: context)
                    }
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
        }
    }

    // MARK: - Aktionen

    private func open(at chapter: Int?) {
        if let readerJump {
            readerJump.jump(chapter)
            return
        }
        if let chapter {
            if chapter != story.currentChapter { story.chapterProgress = 0 }
            story.currentChapter = chapter
        }
        reader.open(story)
    }

    private func downloadAll() async {
        do {
            try await library.downloadAll(story)
            downloadedCount = ContentStore.countDownloaded(story)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportEPUB() async {
        isExporting = true
        defer { isExporting = false }
        do {
            exportedFile = try await library.exportEPUB(story)
            downloadedCount = ContentStore.countDownloaded(story)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func checkUpdates() async {
        do {
            let n = try await library.checkForUpdates(story)
            library.updateMessage = n == 0 ? String(localized: "Keine neuen Kapitel") : String(localized: "\(n) neue Kapitel")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// System-Teilen-Blatt (z. B. „In Dateien sichern“ oder „In Bücher öffnen“).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
