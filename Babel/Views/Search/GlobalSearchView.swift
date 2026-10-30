import SwiftUI
import SwiftData

/// Such-Tab: ohne Eingabe Suchverlauf, gemerkte Fandoms und gespeicherte Filter;
/// mit Eingabe Bibliothek sofort, nach dem Absenden AO3, FanFiction.net und Gutenberg gleichzeitig.
struct GlobalSearchView: View {
    @Query private var allStories: [Story]
    @State private var query = ""
    @State private var showLink = false
    @State private var results = AllSourcesSearch()
    @AppStorage("search.history") private var historyData: Data = Data()
    @AppStorage("ffn.pinned") private var pinnedData: Data = Data()
    @AppStorage(AO3Presets.key) private var ao3PresetData: Data = Data()

    private var trimmed: String { query.trimmed }

    private var matches: [Story] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return allStories.filter { s in
            [[s.title, s.author], s.fandoms, s.relationships, s.characters, s.tags].joined().contains { $0.lowercased().contains(q) }
        }
        .sorted { a, b in
            if a.inLibrary != b.inLibrary { return a.inLibrary }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private var history: [String] { (try? JSONDecoder().decode([String].self, from: historyData)) ?? [] }
    private var pinned: [FFNFandom] { (try? JSONDecoder().decode([FFNFandom].self, from: pinnedData)) ?? [] }
    private var ao3Presets: [SavedAO3Search] { AO3Presets.decode(ao3PresetData) }

    var body: some View {
        List {
            Group {
                if trimmed.isEmpty {
                    startContent
                } else {
                    resultContent
                }
            }
            .themedRows()
        }
        .themedBackground()
        .navigationTitle("Suchen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Bibliothek, AO3, FanFiction.net, Bücher")
        .onSubmit(of: .search) { submit(trimmed) }
        .onChange(of: query) { if trimmed != results.query { results.cancel() } }
        .sheet(isPresented: $showLink) { LinkImportSheet() }
    }

    // MARK: Ohne Eingabe

    @ViewBuilder
    private var startContent: some View {
        if !history.isEmpty {
            Section {
                ForEach(history, id: \.self) { term in
                    Button {
                        query = term
                        submit(term)
                    } label: {
                        Label(term, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                    }
                }
                .onDelete { idx in
                    var list = history
                    list.remove(atOffsets: idx)
                    historyData = (try? JSONEncoder().encode(list)) ?? Data()
                }
            } header: {
                HStack {
                    Text("Letzte Suchen")
                    Spacer()
                    Button("Löschen") { historyData = Data() }.font(.caption).textCase(nil)
                }
            }
        }

        if !pinned.isEmpty {
            Section("Gemerkte Fandoms") {
                ForEach(pinned) { f in
                    NavigationLink(value: f) { Label(f.name, systemImage: "star.fill") }
                }
            }
        }

        if !ao3Presets.isEmpty {
            Section("Gespeicherte AO3-Filter") {
                ForEach(ao3Presets) { preset in
                    NavigationLink(value: AO3SearchRoute(filters: preset.filters, title: preset.name)) {
                        Label(preset.name, systemImage: "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }

        Section {
            Button { showLink = true } label: {
                Label("Link von AO3, FanFiction.net oder EPUB einfügen", systemImage: "link.badge.plus")
            }
        } footer: {
            Text("Die Suche geht über deine Bibliothek, AO3, FanFiction.net und Project Gutenberg gleichzeitig.")
        }
    }

    // MARK: Mit Eingabe

    @ViewBuilder
    private var resultContent: some View {
        if !matches.isEmpty {
            Section("In deiner Bibliothek & Verlauf") {
                ForEach(matches.prefix(results.query == trimmed ? 5 : 30)) { s in
                    NavigationLink(value: s) {
                        StoryRow(story: s.asRemote, localCover: ContentStore.coverFileURL(s),
                                 progress: s.hasStarted ? s.overallProgress : nil, showSummary: false, showSource: true)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                }
            }
        }

        if results.query == trimmed {
            ForEach(AllSourcesSearch.Source.allCases) { source in
                sourceSection(source)
            }
        } else {
            Section {
                Button { submit(trimmed) } label: {
                    Label("„\(trimmed)“ überall suchen", systemImage: "magnifyingglass")
                }
            } footer: {
                Text("AO3, FanFiction.net und Project Gutenberg gleichzeitig.")
            }
        }
    }

    private func sourceSection(_ source: AllSourcesSearch.Source) -> some View {
        let state = results.states[source] ?? .loading
        return Section {
            switch state {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Suche …").font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
            case .done(let stories):
                if stories.isEmpty {
                    Text("Keine Treffer").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(stories.prefix(5)) { story in
                    NavigationLink(value: story) { StoryRow(story: story, showSummary: false) }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .remoteStoryActions(story)
                }
            }
            NavigationLink { fullSearch(source) } label: {
                Text("Alle Treffer auf \(source.label)").font(.subheadline.weight(.medium))
            }
        } header: {
            Label(source.label, systemImage: source.symbol)
        }
    }

    @ViewBuilder
    private func fullSearch(_ source: AllSourcesSearch.Source) -> some View {
        switch source {
        case .ao3: AO3SearchView(initialFilters: AllSourcesSearch.ao3Filters(trimmed), title: "AO3: \(trimmed)")
        case .ffn: FFNKeywordSearchView(initialQuery: trimmed)
        case .books: GutenbergResultsView(query: trimmed)
        }
    }

    private func submit(_ term: String) {
        guard !term.isEmpty else { return }
        var list = history.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        historyData = (try? JSONEncoder().encode(Array(list.prefix(15)))) ?? Data()
        results.run(term)
    }
}

/// Sucht auf allen Quellen gleichzeitig; jede Quelle meldet sich, sobald sie fertig ist.
@MainActor
@Observable
final class AllSourcesSearch {
    enum Source: String, CaseIterable, Identifiable {
        case ao3, ffn, books
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ao3: "AO3"
            case .ffn: "FanFiction.net"
            case .books: "Project Gutenberg"
            }
        }
        var symbol: String {
            switch self {
            case .ao3: StorySource.ao3.symbol
            case .ffn: StorySource.ffn.symbol
            case .books: StorySource.gutenberg.symbol
            }
        }
    }

    enum State {
        case loading
        case done([RemoteStory])
        case failed(String)
    }

    private(set) var query = ""
    private(set) var states: [Source: State] = [:]
    private var tasks: [Task<Void, Never>] = []

    static func ao3Filters(_ term: String) -> AO3Filters {
        var f = AO3Filters.withDefaults
        f.query = term
        return f
    }

    func run(_ term: String) {
        cancel()
        query = term
        states = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, State.loading) })
        for source in Source.allCases {
            tasks.append(Task { [weak self] in
                let state: State
                do {
                    state = .done(try await Self.fetch(source, term))
                } catch {
                    state = .failed(error.localizedDescription)
                }
                guard let self, !Task.isCancelled, self.query == term else { return }
                self.states[source] = state
            })
        }
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
        query = ""
        states = [:]
    }

    private static func fetch(_ source: Source, _ term: String) async throws -> [RemoteStory] {
        switch source {
        case .ao3:
            return try await AO3Service.search(ao3Filters(term), page: 1).works
        case .ffn:
            return try await FFNService.search(keywords: term, page: 1).stories
        case .books:
            var f = GutenbergFilters()
            f.query = term
            f.language = ""
            return try await BookLibrary.gutenberg.search(f, page: 1).books
        }
    }
}

/// Alle Gutenberg-Treffer zu einem Suchbegriff (alle Sprachen), seitenweise – ohne die Filter des Bücher-Tabs anzufassen.
struct GutenbergResultsView: View {
    let query: String
    @State private var books: [RemoteStory] = []
    @State private var page = 0
    @State private var hasNext = true
    @State private var error: String?

    var body: some View {
        List {
            ForEach(books) { book in
                NavigationLink(value: book) { StoryRow(story: book) }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .remoteStoryActions(book)
            }
            .themedRows(grouped: false)
            if hasNext && error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
                    .task(id: page) { await loadNext() }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle("Gutenberg: \(query)")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let error, books.isEmpty {
                ErrorBanner(message: error) { self.error = nil }
            } else if !hasNext && books.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func loadNext() async {
        var f = GutenbergFilters()
        f.query = query
        f.language = ""
        do {
            let result = try await BookLibrary.gutenberg.search(f, page: page + 1)
            let known = Set(books.map(\.id))
            books += result.books.filter { !known.contains($0.id) }
            page += 1
            hasNext = result.hasNext && !result.books.isEmpty
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// Link einfügen → Geschichte landet direkt in der Bibliothek.
struct LinkImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @Environment(ReaderPresenter.self) private var reader

    @State private var link = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var imported: Story?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://archiveofourown.org/works/…", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { link = s }
                    }
                } footer: {
                    Text("Funktioniert mit AO3-Werken, FanFiction.net-Geschichten und direkten .epub-Links.")
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                if let imported {
                    Section("Hinzugefügt") {
                        StoryRow(story: imported.asRemote, localCover: ContentStore.coverFileURL(imported), showSummary: false, showSource: true)
                        Button("Jetzt lesen", systemImage: "book.fill") {
                            dismiss()
                            reader.open(imported)
                        }
                    }
                }
            }
            .navigationTitle("Link hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Hinzufügen", systemImage: "checkmark") { Task { await importLink() } }
                            .disabled(link.trimmed.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func importLink() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            imported = try await library.importLink(link, context: context)
            link = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
