import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Freie Online-Bücher (Project Gutenberg) + eigene EPUBs.
struct BooksView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @AppStorage("books.filters") private var filtersData: Data = Data()

    @State private var filters = GutenbergFilters()
    @State private var didLoadFilters = false
    @State private var books: [RemoteStory] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var showFilters = false
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            GlassChip(title: "Alle", isSelected: filters.subject.isEmpty) { setSubject("") }
                            ForEach(GutenbergService.subjects, id: \.query) { s in
                                GlassChip(title: s.label, isSelected: filters.subject == s.query) { setSubject(s.query) }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section(sectionTitle) {
                ForEach(books) { book in
                    NavigationLink(value: book) { StoryRow(story: book) }
                        .remoteStoryActions(book)
                }
                if hasNext {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .task { await load(page: page + 1) }
                }
            }
            .themedRows()
        }
        .themedBackground()
        .navigationTitle("Bücher")
        .searchable(text: $filters.query, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        .searchScopes($filters.scope, activation: .onSearchPresentation) {
            ForEach(GutenbergScope.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .onSubmit(of: .search) { reload() }
        .onChange(of: filters.scope) { if !filters.query.trimmed.isEmpty { reload() } }
        .onChange(of: filters.query) { old, new in
            // Suchfeld geleert (z. B. mit dem x) → wieder die beliebtesten Bücher zeigen.
            if !old.isEmpty && new.isEmpty { reload() }
        }
        .overlay {
            if isLoading && books.isEmpty {
                ProgressView("Lade Bücher …")
            } else if let error, books.isEmpty {
                ErrorBanner(message: error) { reload() }
            } else if !isLoading && books.isEmpty {
                ContentUnavailableView("Keine Bücher", systemImage: "books.vertical", description: Text("Versuch es mit weniger Filtern."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Label("Eigenes EPUB importieren", systemImage: "doc.badge.plus")
                }
                Menu {
                    Picker("Sortieren nach", selection: $filters.sort) {
                        ForEach(GutenbergSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    showFilters = true
                } label: {
                    Label("Filter", systemImage: filters.activeCount > 0
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .badge(filters.activeCount)
            }
        }
        .sheet(isPresented: $showFilters) {
            GutenbergFilterSheet(filters: filters) { new in
                filters = new
                reload()
            }
        }
        .onChange(of: filters.sort) { reload() }
        .onChange(of: filters) { _, new in filtersData = (try? JSONEncoder().encode(new)) ?? Data() }
        .task {
            if !didLoadFilters {
                didLoadFilters = true
                if let saved = try? JSONDecoder().decode(GutenbergFilters.self, from: filtersData) { filters = saved }
            }
            if books.isEmpty { await load(page: 1) }
        }
        .refreshable { await load(page: 1) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var ok = 0
            var failures: [String] = []
            for url in urls {
                do { _ = try library.importEPUB(at: url, context: context); ok += 1 }
                catch { failures.append(error.localizedDescription) }
            }
            importMessage = failures.isEmpty ? "\(ok) Buch/Bücher in deine Bibliothek gelegt." : failures.joined(separator: "\n")
        }
        .alert("Import", isPresented: .constant(importMessage != nil), presenting: importMessage) { _ in
            Button("OK") { importMessage = nil }
        } message: { Text($0) }
    }

    private var sectionTitle: String {
        let isBrowsing = filters.query.trimmed.isEmpty && filters.activeCount == 0
        return isBrowsing ? "\(filters.sort.label) bei Project Gutenberg" : "Ergebnisse bei Project Gutenberg"
    }

    private var searchPrompt: String {
        switch filters.scope {
        case .all: "Titel, Autor:in, Thema …"
        case .title: "Titel suchen"
        case .author: "Autor:in suchen, z. B. Kafka"
        case .subject: "Thema suchen (englisch, z. B. poetry)"
        }
    }

    private func setSubject(_ subject: String) {
        withAnimation(.snappy) { filters.subject = subject }
        reload()
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load(page: 1) }
    }

    private func load(page: Int) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let current = filters
        do {
            let result = try await GutenbergService.search(current, page: page)
            guard !Task.isCancelled, current == filters else { return }
            if page == 1 {
                books = result.books
            } else {
                let known = Set(books.map(\.id))
                books += result.books.filter { !known.contains($0.id) }
            }
            self.page = page
            hasNext = result.hasNext
        } catch {
            guard !Task.isCancelled else { return }
            if page == 1 { books = []; self.error = error.localizedDescription }
            hasNext = false
        }
    }
}

struct GutenbergFilterSheet: View {
    var onApply: (GutenbergFilters) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GutenbergFilters

    init(filters: GutenbergFilters, onApply: @escaping (GutenbergFilters) -> Void) {
        self.onApply = onApply
        _draft = State(initialValue: filters)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Suche") {
                    TextField("Freitext", text: $draft.query)
                    TextField("Titel", text: $draft.title)
                    TextField("Autor:in", text: $draft.author)
                        .textInputAutocapitalization(.words)
                    TextField("Thema (z. B. poetry, history)", text: $draft.subject)
                        .textInputAutocapitalization(.never)
                }
                .themedRows()
                Section {
                    Picker("Sprache", selection: $draft.language) {
                        ForEach(GutenbergService.languages) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Sortieren nach", selection: $draft.sort) {
                        ForEach(GutenbergSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("Gutenberg sucht nach englischen Begriffen am zuverlässigsten, auch bei deutschen Büchern (Thema „poetry“ statt „Lyrik“).")
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") {
                        let language = draft.language
                        draft = GutenbergFilters()
                        draft.language = language
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anwenden", systemImage: "checkmark") {
                        dismiss()
                        onApply(draft)
                    }
                }
            }
        }
    }
}
