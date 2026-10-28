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
    @Query(sort: \Shelf.createdAt) private var shelves: [Shelf]

    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showAllChapters = false
    @State private var downloadedCount = 0
    @State private var exportedFile: URL?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                if story.inLibrary { organize }
                stats
                if !story.summary.isEmpty { summary }
                tagSections
                chapters
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await library.enrichGutenberg(story) }
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
                    Text(story.author).font(.headline).foregroundStyle(.secondary)
                }
                TagChip(text: story.source.label, tint: story.source.tint, symbol: story.source.symbol)
                if story.newChapters > 0 {
                    Label(story.newChapters == 1 ? "1 neues Kapitel" : "\(story.newChapters) neue Kapitel", systemImage: "sparkles")
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
                    Label(story.hasStarted ? "Weiterlesen" : "Lesen", systemImage: "book.fill")
                        .foregroundStyle(theme.primaryForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.primary)

                Button {
                    if story.inLibrary { library.removeFromLibrary(story, context: context) }
                    else { library.addToLibrary(story, context: context) }
                } label: {
                    Image(systemName: story.inLibrary ? "checkmark" : "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(story.inLibrary ? "Aus Bibliothek entfernen" : "Zur Bibliothek hinzufügen")

                if story.source.isWebFiction || story.spinePaths.isEmpty {
                    Button {
                        Task { await downloadAll() }
                    } label: {
                        if let p = library.downloads[story.key] {
                            ProgressView(value: p).progressViewStyle(.circular).frame(width: 26, height: 26)
                        } else {
                            Image(systemName: isFullyDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .frame(width: 26, height: 26)
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
                        .frame(width: 26, height: 26)
                        .foregroundStyle(story.isFavorite ? .pink : .primary)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Favorit")
            }
        }
        .controlSize(.large)
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
                Label(story.shelves.isEmpty ? "Sammlung" : story.shelves.map(\.name).joined(separator: ", "),
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
        add("Wörter", story.words?.grouped, "textformat.size")
        add("Kapitel", chapterLabel, "list.number")
        add("Kudos", story.kudos?.compact, "heart")
        add(story.source == .gutenberg ? "Downloads" : "Aufrufe", story.hits?.compact, "eye")
        add("Reviews", story.reviews?.compact, "text.bubble")
        add("Favs", story.favs?.compact, "star")
        add("Follows", story.follows?.compact, "bell")
        add("Lesezeichen", story.bookmarks?.compact, "bookmark")
        add("Aktualisiert", story.lastUpdated?.formatted(date: .abbreviated, time: .omitted), "clock")
        add("Veröffentlicht", story.published?.formatted(date: .abbreviated, time: .omitted), "calendar")
        add("Sprache", story.language, "globe")
        add("Rating", story.rating, "exclamationmark.shield")
        return items
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
        if story.source == .epub || story.source == .gutenberg {
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
        tagSection("Warnungen", story.warnings, tint: .orange)
        tagSection("Kategorien", story.categories)
        tagSection("Genres", story.genres)
        tagSection("Beziehungen", story.relationships, tint: .pink)
        tagSection("Charaktere", story.characters, tint: .blue)
        tagSection(story.source == .gutenberg ? "Themen" : "Tags", story.tags)
    }

    @ViewBuilder
    private func tagSection(_ title: String, _ tags: [String], tint: Color? = nil) -> some View {
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        if story.source == .ao3 {
                            NavigationLink(value: TagSearchRoute(tag: tag)) { TagChip(text: tag, tint: tint) }
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
                    if count > 12 {
                        Button(showAllChapters ? "Weniger" : "Alle \(count)") { withAnimation { showAllChapters.toggle() } }
                            .font(.subheadline)
                    }
                }
                .padding(.bottom, 8)
                ForEach(0..<(showAllChapters ? count : min(count, 12)), id: \.self) { i in
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
            library.updateMessage = n == 0 ? "Keine neuen Kapitel" : "\(n) neue Kapitel"
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
