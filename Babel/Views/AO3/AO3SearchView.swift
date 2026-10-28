import SwiftUI

@MainActor
@Observable
final class AO3SearchModel {
    var filters: AO3Filters
    var results: [RemoteStory] = []
    var total: Int?
    var page = 1
    var hasNext = false
    var isLoading = false
    var hasSearched = false
    var error: String?

    init(filters: AO3Filters = AO3Filters()) {
        self.filters = filters
    }

    func search() async {
        page = 1
        hasNext = false
        error = nil
        isLoading = true
        defer { isLoading = false; hasSearched = true }
        do {
            let result = try await AO3Service.search(filters, page: 1)
            let text = filters.title.trimmed.isEmpty ? filters.query : filters.title
            results = filters.sort == .bestMatch ? TitleRanking.rank(result.works, query: text) : result.works
            total = result.total
            hasNext = result.hasNext
        } catch {
            results = []
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasNext, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await AO3Service.search(filters, page: page + 1)
            page += 1
            let known = Set(results.map(\.id))
            results += result.works.filter { !known.contains($0.id) }
            hasNext = result.hasNext
        } catch {
            hasNext = false
            self.error = error.localizedDescription
        }
    }
}

/// Navigationsziel: Ergebnisse für bestimmte Filter.
struct AO3SearchRoute: Hashable {
    var filters: AO3Filters
    var title: String
}

// MARK: - Filterwand (Startseite des AO3-Tabs)

struct AO3FilterWallView: View {
    @AppStorage(AO3Presets.key) private var savedData: Data = Data()
    @AppStorage("ao3.lastFilters") private var lastData: Data = Data()
    @State private var draft = AO3Filters()
    @State private var didLoad = false
    @Binding var path: NavigationPath
    @State private var showSave = false
    @State private var presetName = ""
    @State private var loadedPreset: String?
    @State private var keyboardVisible = false
    @Environment(\.theme) private var theme

    private var presets: [SavedAO3Search] { AO3Presets.decode(savedData) }

    var body: some View {
        Form {
            if !presets.isEmpty {
                Section {
                    ForEach(presets) { preset in
                        Button {
                            withAnimation { draft = preset.filters; loadedPreset = preset.name }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name).font(.headline)
                                    Text(preset.filters.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if loadedPreset == preset.name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button("Suchen", systemImage: "magnifyingglass") { search(preset.filters, title: preset.name) }
                                .tint(.accentColor)
                        }
                        .contextMenu {
                            Button("Sofort suchen", systemImage: "magnifyingglass") { search(preset.filters, title: preset.name) }
                            Button("Mit aktuellen Filtern überschreiben", systemImage: "square.and.arrow.down") {
                                savedData = AO3Presets.saving(preset.name, draft, into: savedData)
                            }
                            Button("Löschen", systemImage: "trash", role: .destructive) { delete(preset) }
                        }
                    }
                    .onDelete { idx in
                        var list = presets
                        list.remove(atOffsets: idx)
                        savedData = AO3Presets.encode(list)
                    }
                } header: {
                    Text("Gespeicherte Filter")
                } footer: {
                    Text("Tippen lädt die Filter, nach rechts wischen sucht sofort.")
                }
                .themedRows()
            }

            Section("Schnellstart") {
                FlowLayout(spacing: 8) {
                    quick("Neu aktualisiert", sort: .updated)
                    quick("Meiste Kudos", sort: .kudos)
                    quick("Abgeschlossen & beliebt", sort: .kudos, complete: true)
                    quick("Auf Deutsch", sort: .updated, language: "de")
                }
                .padding(.vertical, 4)
            }
            .themedRows()

            AO3FilterSections(draft: $draft)
        }
        .themedBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("AO3")
        .safeAreaInset(edge: .bottom) {
            // Beim Tippen verschwindet der Knopf, damit er nicht über der Tastatur das Formular verdeckt.
            if !keyboardVisible {
                Button {
                    search(draft, title: draft.summary == "Alle Werke" ? "AO3" : draft.summary)
                } label: {
                    Label(draft.activeCount > 0 ? "Suchen · \(draft.activeCount)" : "Suchen", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryForeground)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .padding(.bottom, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    AO3AccountView()
                } label: {
                    Label("Konto", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Filter speichern …", systemImage: "square.and.arrow.down") {
                        presetName = loadedPreset ?? draft.summary
                        showSave = true
                    }
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise", role: .destructive) {
                        withAnimation { draft = AO3Filters(); loadedPreset = nil }
                    }
                } label: {
                    Label("Mehr", systemImage: "ellipsis")
                }
            }
        }
        .alert("Filter speichern", isPresented: $showSave) {
            TextField("Name", text: $presetName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                let name = presetName.trimmed
                guard !name.isEmpty else { return }
                savedData = AO3Presets.saving(name, draft, into: savedData)
                loadedPreset = name
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let last = try? JSONDecoder().decode(AO3Filters.self, from: lastData) { draft = last }
        }
        .onChange(of: draft) { _, new in
            lastData = (try? JSONEncoder().encode(new)) ?? Data()
        }
    }

    private func search(_ filters: AO3Filters, title: String) {
        path.append(AO3SearchRoute(filters: filters, title: title))
    }

    private func delete(_ preset: SavedAO3Search) {
        savedData = AO3Presets.encode(presets.filter { $0.id != preset.id })
        if loadedPreset == preset.name { loadedPreset = nil }
    }

    private func quick(_ title: String, sort: AO3Sort, complete: Bool = false, language: String = "") -> some View {
        Button(title) {
            var f = draft
            f.sort = sort
            f.ascending = false
            if complete { f.completion = .complete }
            if !language.isEmpty { f.language = language }
            search(f, title: title)
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Ergebnisse

/// Worin das Suchfeld auf der Ergebnisseite sucht.
enum AO3SearchScope: String, CaseIterable {
    case all, title, author
    var label: String {
        switch self { case .all: "Alles"; case .title: "Titel"; case .author: "Autor:in" }
    }
    var prompt: String {
        switch self { case .all: "Werke, Tags, Autor:innen …"; case .title: "Titel"; case .author: "Autor:in" }
    }
}

struct AO3SearchView: View {
    var initialFilters: AO3Filters
    var title: String = "AO3"

    @State private var model = AO3SearchModel()
    @State private var showFilters = false
    @State private var didStart = false
    @State private var showSave = false
    @State private var presetName = ""
    @State private var searchText = ""
    @AppStorage("ao3.searchScope") private var scope: AO3SearchScope = .all
    @AppStorage(AO3Presets.key) private var savedData: Data = Data()

    var body: some View {
        List {
            if let total = model.total, model.hasSearched {
                Text("\(total.grouped) Werke gefunden")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
            }

            ForEach(model.results) { work in
                NavigationLink(value: work) { StoryRow(story: work) }
                    .remoteStoryActions(work)
            }
            .themedRows(grouped: false)

            if model.hasNext {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
                    .task { await model.loadMore() }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: scope.prompt)
        .searchScopes($scope, activation: .onSearchPresentation) {
            ForEach(AO3SearchScope.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .onSubmit(of: .search) { applySearchText() }
        .onChange(of: scope) { if !searchText.trimmed.isEmpty { applySearchText() } }
        .overlay {
            if model.isLoading && model.results.isEmpty {
                SlowLoadingView(text: "Suche auf AO3 …", slowHint: "AO3 ist gerade langsam. Das kann bis zu einer Minute dauern.")
            } else if let error = model.error, model.results.isEmpty {
                ErrorBanner(message: error) { Task { await model.search() } }
            } else if model.hasSearched && model.results.isEmpty {
                ContentUnavailableView("Keine Treffer", systemImage: "magnifyingglass",
                                       description: Text("Versuch es mit weniger Filtern."))
            }
        }
        .refreshable { await model.search() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sortieren nach", selection: $model.filters.sort) {
                        ForEach(AO3Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Aufsteigend", isOn: $model.filters.ascending)
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    showFilters = true
                } label: {
                    Label("Filter", systemImage: model.filters.activeCount > 0
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .badge(model.filters.activeCount)
                Button("Filter speichern", systemImage: "bookmark") {
                    presetName = title
                    showSave = true
                }
            }
        }
        .onChange(of: model.filters.sort) { if model.hasSearched { Task { await model.search() } } }
        .onChange(of: model.filters.ascending) { if model.hasSearched { Task { await model.search() } } }
        .sheet(isPresented: $showFilters) {
            AO3FilterView(filters: $model.filters) {
                Task { await model.search() }
            }
        }
        .alert("Filter speichern", isPresented: $showSave) {
            TextField("Name", text: $presetName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                let name = presetName.trimmed
                if !name.isEmpty { savedData = AO3Presets.saving(name, model.filters, into: savedData) }
            }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            model.filters = initialFilters
            searchText = initialFilters.query
            await model.search()
        }
    }

    /// Text aus dem Suchfeld in das passende Filterfeld schreiben und neu suchen.
    private func applySearchText() {
        let text = searchText.trimmed
        switch scope {
        case .all: model.filters.query = text
        case .title: model.filters.title = text; model.filters.query = ""
        case .author: model.filters.author = text; model.filters.query = ""
        }
        Task { await model.search() }
    }
}
