import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum LibraryFilter: Hashable {
    case all, updates, favorites, offline, history
    case status(ReadingStatus)
    case source(StorySource)
    case shelf(String)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, added, updated, title, author, progress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: String(localized: "Zuletzt gelesen")
        case .added: String(localized: "Zuletzt hinzugefügt")
        case .updated: String(localized: "Zuletzt aktualisiert")
        case .title: String(localized: "Titel")
        case .author: String(localized: "Autor:in")
        case .progress: String(localized: "Fortschritt")
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @Environment(ReaderPresenter.self) private var reader
    @Environment(\.theme) private var theme

    @Query(filter: #Predicate<Story> { $0.inLibrary }) private var stories: [Story]
    @Query(filter: #Predicate<Story> { $0.viewedAt != nil || $0.lastOpenedAt != nil }) private var history: [Story]
    @Query(sort: \Shelf.createdAt) private var shelves: [Shelf]

    @State private var filter: LibraryFilter = .all
    @AppStorage("library.sort") private var sort: LibrarySort = .recent
    @State private var searchText = ""
    @State private var query = LibraryQuery()
    @State private var showQuery = false
    @State private var showImporter = false
    @State private var showLinkSheet = false
    @State private var showSettings = false
    @State private var showNewShelf = false
    @State private var newShelfName = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(filtered) { story in
                    NavigationLink(value: story) {
                        StoryRow(
                            story: story.asRemote,
                            localCover: ContentStore.coverFileURL(story),
                            progress: story.hasStarted ? story.overallProgress : nil,
                            newChapters: story.newChapters,
                            showSummary: true,
                            showSource: true
                        )
                    }
                    // Ohne Pfeil rechts – gleicher Rand links und rechts wie in allen Geschichtenlisten.
                    .navigationLinkIndicatorVisibility(.hidden)
                    .swipeActions(edge: .leading) {
                        Button { reader.open(story) } label: { Label("Lesen", systemImage: "book.fill") }
                            .tint(theme.primary)
                    }
                    .librarySwipeActions(story)
                    .contextMenu { StoryContextMenu(story: story) }
                }
                .themedRows(grouped: false)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    filterBar
                    if query.activeCount > 0 { activeQueryBar }
                }
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }

            // Unter „Alle“: zuletzt angesehene Geschichten, die (noch) nicht in der Bibliothek liegen.
            if filter == .all && searchText.trimmed.isEmpty && !recentlyViewed.isEmpty {
                Section {
                    ForEach(recentlyViewed.prefix(8)) { story in
                        NavigationLink(value: story) {
                            StoryRow(story: story.asRemote, localCover: ContentStore.coverFileURL(story),
                                     progress: story.hasStarted ? story.overallProgress : nil, showSummary: false, showSource: true)
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .librarySwipeActions(story)
                    }
                    .themedRows(grouped: false)
                    if recentlyViewed.count > 8 {
                        Button("Ganzen Verlauf anzeigen (\(history.count))") { withAnimation(.snappy) { filter = .history } }
                            .themedRows(grouped: false)
                    }
                } header: {
                    Label("Zuletzt angesehen", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle("Bibliothek")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titel, Autor:in, Fandom, Pairing, Tag")
        .overlay {
            if stories.isEmpty && history.isEmpty {
                emptyState
            } else if filtered.isEmpty && !searchText.trimmed.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if filtered.isEmpty && !(filter == .all && !recentlyViewed.isEmpty) {
                ContentUnavailableView("Hier ist noch nichts", systemImage: "tray",
                                       description: Text("In dieser Auswahl liegen keine Geschichten."))
            }
        }
        .refreshable { await library.checkAllUpdates(context: context) }
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .sheet(isPresented: $showLinkSheet) { LinkImportSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showQuery) {
            LibraryFilterSheet(query: $query, stories: stories)
        }
        .alert("Neue Sammlung", isPresented: $showNewShelf) {
            TextField("Name", text: $newShelfName)
            Button("Abbrechen", role: .cancel) { newShelfName = "" }
            Button("Anlegen") {
                let name = newShelfName.trimmed
                if !name.isEmpty { context.insert(Shelf(name: name)); try? context.save() }
                newShelfName = ""
            }
        }
        .alert("Fehler", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    // MARK: - Filter

    private struct ChipItem: Identifiable {
        let title: String
        let symbol: String?
        let value: LibraryFilter
        let count: Int
        var id: String { title }
    }

    /// Alle Filter-Chips mit Anzahl – „Alle“ vorn, der Rest nach Anzahl sortiert.
    private var chipItems: [ChipItem] {
        func count(_ f: LibraryFilter) -> Int { stories.filter { matches($0, f) }.count }
        var items: [ChipItem] = []
        func add(_ title: String, _ symbol: String?, _ value: LibraryFilter, hideEmpty: Bool = false) {
            let n = value == .history ? history.count : count(value)
            if hideEmpty && n == 0 { return }
            items.append(ChipItem(title: title, symbol: symbol, value: value, count: n))
        }
        add(String(localized: "Neue Kapitel"), "sparkles", .updates, hideEmpty: true)
        for status in [ReadingStatus.reading, .planned, .finished, .paused, .dropped] {
            add(status.label, status.symbol, .status(status))
        }
        add(String(localized: "Favoriten"), "heart.fill", .favorites)
        add(String(localized: "Offline"), "arrow.down.circle.fill", .offline, hideEmpty: true)
        for shelf in shelves { add(shelf.name, shelf.symbol, .shelf(shelf.name)) }
        // AO3 und FFN immer anbieten, Gutenberg/EPUB nur, wenn etwas da ist.
        for source in StorySource.allCases { add(source.shortLabel, source.symbol, .source(source), hideEmpty: !source.isWebFiction) }
        add(String(localized: "Verlauf"), "clock.arrow.circlepath", .history, hideEmpty: true)
        // Stabil sortieren: bei gleicher Anzahl bleibt die Reihenfolge von oben.
        let sorted = items.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
        return [ChipItem(title: String(localized: "Alle"), symbol: nil, value: .all, count: stories.count)] + sorted
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(chipItems) { item in
                        chip(item.count > 0 && item.value != .all ? "\(item.title) \(item.count)" : item.title, item.symbol, item.value)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    /// Aktive Filter als Chips zum Wegtippen, dazu die Trefferzahl.
    private var activeQueryBar: some View {
        var items: [(String, () -> Void)] = []
        for f in query.fandoms.sorted() { items.append((f, { query.fandoms.remove(f) })) }
        for p in query.pairings.sorted() { items.append((p, { query.pairings.remove(p) })) }
        for c in query.characters.sorted() { items.append((c, { query.characters.remove(c) })) }
        for r in query.ratings.sorted() { items.append((String(localized: "Rating \(r)"), { query.ratings.remove(r) })) }
        if query.completion != .any { items.append((query.completion.label, { query.completion = .any })) }
        if query.length != .any { items.append((query.length.label, { query.length = .any })) }
        for l in query.languages.sorted() { items.append((l, { query.languages.remove(l) })) }
        for s in query.sources.sorted(by: { $0.rawValue < $1.rawValue }) { items.append((s.shortLabel, { query.sources.remove(s) })) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("\(filtered.count) Treffer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        withAnimation(.snappy) { item.1() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(item.0).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(theme.primary.opacity(0.2)).interactive(), in: .capsule)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, _ symbol: String?, _ value: LibraryFilter) -> some View {
        GlassChip(title: title, symbol: symbol, isSelected: filter == value) {
            withAnimation(.snappy) { filter = value }
        }
    }

    private func matches(_ story: Story, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all, .history: true
        case .updates: story.newChapters > 0
        case .favorites: story.isFavorite
        case .offline: story.source.isWebFiction ? story.downloadedCount >= story.knownChapterCount : !story.spinePaths.isEmpty
        case .status(let s): story.status == s
        case .source(let s): story.source == s
        case .shelf(let name): story.shelves.contains { $0.name == name }
        }
    }

    private var filtered: [Story] {
        // Verlauf: alles, was angesehen oder gelesen wurde – auch ohne „in die Bibliothek“.
        var list = filter == .history ? history : stories.filter { matches($0, filter) }
        if query.activeCount > 0 { list = list.filter(query.matches) }
        // Jedes Wort muss irgendwo vorkommen: Titel, Autor:in, Fandom, Pairing, Charaktere, Tags, Genres, Zusammenfassung.
        let words = searchText.trimmed.lowercased().split(separator: " ")
        if !words.isEmpty {
            list = list.filter { s in
                let haystack = ([s.title, s.author, s.summary] + s.fandoms + s.relationships + s.characters + s.tags + s.genres)
                    .joined(separator: " ").lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
        }
        if filter == .history {
            return list.sorted { Self.lastSeen($0) > Self.lastSeen($1) }
        }
        switch sort {
        case .recent: list.sort { Self.recency($0) > Self.recency($1) }
        case .added: list.sort { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        case .updated: list.sort { ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast) }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: list.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .progress: list.sort { $0.overallProgress > $1.overallProgress }
        }
        return list
    }

    private var recentlyViewed: [Story] {
        history.filter { !$0.inLibrary }.sorted { Self.lastSeen($0) > Self.lastSeen($1) }
    }

    private static func lastSeen(_ s: Story) -> Date {
        max(s.viewedAt ?? .distantPast, s.lastOpenedAt ?? .distantPast)
    }

    private static func recency(_ s: Story) -> Date {
        if let d = s.lastOpenedAt { return d }
        if let d = s.addedAt { return d }
        return Date.distantPast
    }

    // MARK: - Toolbar & Zustände

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
        }
        if library.isCheckingUpdates {
            ToolbarItem(placement: .principal) {
                Label("Suche nach neuen Kapiteln", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
                    .symbolEffect(.rotate, options: .repeating)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Suche nach neuen Kapiteln")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showQuery = true
            } label: {
                Label("Filter", systemImage: query.activeCount > 0
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .badge(query.activeCount)
            Menu {
                Picker("Sortieren", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sortieren", systemImage: "arrow.up.arrow.down")
            }
            Menu {
                Button("EPUB importieren", systemImage: "doc.badge.plus") { showImporter = true }
                Button("Link hinzufügen", systemImage: "link.badge.plus") { showLinkSheet = true }
                Divider()
                Button("Neue Sammlung", systemImage: "folder.badge.plus") { showNewShelf = true }
                if library.isCheckingUpdates {
                    Label("Suche nach Updates …", systemImage: "hourglass")
                } else {
                    Button("Nach neuen Kapiteln suchen", systemImage: "arrow.clockwise") {
                        Task { await library.checkAllUpdates(context: context) }
                    }
                }
            } label: {
                Label("Hinzufügen", systemImage: "plus")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Deine Bibliothek ist leer", systemImage: "books.vertical")
        } description: {
            Text("Such dir auf AO3 oder FanFiction.net etwas aus, importiere ein EPUB oder füge einen Link ein.")
        } actions: {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button { showImporter = true } label: {
                        Label("EPUB importieren", systemImage: "doc.badge.plus").foregroundStyle(theme.primaryForeground)
                    }
                    .buttonStyle(.glassProminent)
                    Button("Link hinzufügen", systemImage: "link") { showLinkSheet = true }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var failures: [String] = []
            for url in urls {
                do { _ = try library.importEPUB(at: url, context: context) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

/// Kontextmenü für eine Geschichte (Status, Favorit, Sammlungen).
struct StoryContextMenu: View {
    @Bindable var story: Story
    @Environment(\.modelContext) private var context
    @Environment(ReaderPresenter.self) private var reader
    @Query(sort: \Shelf.createdAt) private var shelves: [Shelf]

    var body: some View {
        Button(story.hasStarted ? String(localized: "Weiterlesen") : String(localized: "Lesen"), systemImage: "book.fill") { reader.open(story) }
        Picker("Status", selection: $story.status) {
            ForEach(ReadingStatus.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
        }
        Toggle(isOn: $story.isFavorite) { Label("Favorit", systemImage: "heart") }
        if !shelves.isEmpty {
            Menu("Sammlungen", systemImage: "folder") {
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
            }
        }
    }
}

/// Wischen in der Bibliothek: Laden, Favorit, Löschen – runde Glasknöpfe von iOS in gedämpften Themefarben.
/// Ganz durchwischen löscht.
struct LibrarySwipeActions: ViewModifier {
    @Bindable var story: Story
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @Environment(\.theme) private var theme

    private var isDownloaded: Bool {
        story.source.isWebFiction
            ? story.downloadedCount > 0 && story.downloadedCount >= story.knownChapterCount
            : !story.spinePaths.isEmpty
    }

    func body(content: Content) -> some View {
        content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation { remove() }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
            .tint(theme.exclude)

            Button {
                story.isFavorite.toggle()
                try? context.save()
            } label: {
                Label(story.isFavorite ? "Kein Favorit" : "Favorit", systemImage: story.isFavorite ? "heart.slash.fill" : "heart.fill")
            }
            .tint(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xD39C96) : UIColor(hex: 0xB0726D) }))

            if story.source != .epub {
                Button {
                    download()
                } label: {
                    Label(isDownloaded ? "Offline" : "Laden", systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                }
                .tint(theme.primary)
                .disabled(isDownloaded || library.downloads[story.key] != nil)
            }
        }
    }

    /// Aus der Bibliothek nehmen, Offline-Kopie und Verlaufseintrag entfernen.
    /// Eigene EPUBs gibt es nur lokal – die verschwinden ganz.
    private func remove() {
        if story.source == .epub {
            library.delete(story, context: context)
            return
        }
        library.removeFromLibrary(story, context: context)
        library.deleteOfflineContent(story, context: context)
        if !story.source.isWebFiction { ContentStore.deleteContent(of: story); story.spinePaths = [] }
        story.viewedAt = nil
        story.lastOpenedAt = nil
        story.userRemoved = true
        try? context.save()
    }

    private func download() {
        if !story.inLibrary { library.addToLibrary(story, context: context) }
        library.showProgress(String(localized: "Lade „\(story.title)“ …"))
        Task {
            do {
                try await library.downloadAll(story)
                library.updateMessage = String(localized: "„\(story.title)“ offline gespeichert")
            } catch {
                library.updateMessage = String(localized: "Download fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }
}

extension View {
    func librarySwipeActions(_ story: Story) -> some View { modifier(LibrarySwipeActions(story: story)) }
}
