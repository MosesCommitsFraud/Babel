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
        case .recent: "Zuletzt gelesen"
        case .added: "Zuletzt hinzugefügt"
        case .updated: "Zuletzt aktualisiert"
        case .title: "Titel"
        case .author: "Autor:in"
        case .progress: "Fortschritt"
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
                            showSummary: false
                        )
                    }
                    .swipeActions(edge: .leading) {
                        Button { reader.open(story) } label: { Label("Lesen", systemImage: "book.fill") }
                            .tint(theme.primary)
                    }
                    .swipeActions(edge: .trailing) {
                        if story.inLibrary {
                            Button(role: .destructive) { library.removeFromLibrary(story, context: context) } label: {
                                Label("Entfernen", systemImage: "trash")
                            }
                        } else {
                            Button { library.addToLibrary(story, context: context) } label: {
                                Label("Merken", systemImage: "bookmark")
                            }
                            .tint(.indigo)
                            Button(role: .destructive) {
                                story.viewedAt = nil
                                story.lastOpenedAt = nil
                                try? context.save()
                            } label: {
                                Label("Aus Verlauf", systemImage: "clock.badge.xmark")
                            }
                        }
                        Button { story.isFavorite.toggle() } label: {
                            Label("Favorit", systemImage: story.isFavorite ? "heart.slash" : "heart")
                        }
                        .tint(.pink)
                    }
                    .contextMenu { StoryContextMenu(story: story) }
                }
                .themedRows(grouped: false)
            } header: {
                filterBar
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle("Bibliothek")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Titel, Autor:in, Fandom, Tag")
        .overlay {
            if stories.isEmpty && history.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .refreshable { await library.checkAllUpdates(context: context) }
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .sheet(isPresented: $showLinkSheet) { LinkImportSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        add("Neue Kapitel", "sparkles", .updates, hideEmpty: true)
        for status in [ReadingStatus.reading, .planned, .finished, .paused, .dropped] {
            add(status.label, status.symbol, .status(status))
        }
        add("Favoriten", "heart.fill", .favorites)
        add("Offline", "arrow.down.circle.fill", .offline, hideEmpty: true)
        for shelf in shelves { add(shelf.name, shelf.symbol, .shelf(shelf.name)) }
        for source in StorySource.allCases { add(source.shortLabel, source.symbol, .source(source), hideEmpty: true) }
        add("Verlauf", "clock.arrow.circlepath", .history, hideEmpty: true)
        // Stabil sortieren: bei gleicher Anzahl bleibt die Reihenfolge von oben.
        let sorted = items.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
        return [ChipItem(title: "Alle", symbol: nil, value: .all, count: stories.count)] + sorted
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
        let q = searchText.trimmed.lowercased()
        if !q.isEmpty {
            list = list.filter { s in
                [[s.title, s.author], s.fandoms, s.relationships, s.characters, s.tags].joined()
                    .contains { $0.lowercased().contains(q) }
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
        ToolbarItemGroup(placement: .topBarTrailing) {
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
        Button(story.hasStarted ? "Weiterlesen" : "Lesen", systemImage: "book.fill") { reader.open(story) }
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
