import SwiftUI

// MARK: - Fandom-Listen (alle Kategorien, zwischengespeichert)

/// Hält die Fandom-Listen aller Kategorien, damit man über alle Franchises hinweg suchen kann.
/// Liegt 7 Tage im Cache-Ordner – FFN-Seiten zu laden ist langsam (Cloudflare, Pausen).
@MainActor
@Observable
final class FFNFandomStore {
    static let shared = FFNFandomStore()
    private(set) var lists: [String: [FFNFandom]] = [:]
    private(set) var isLoadingAll = false

    private struct Snapshot: Codable {
        var date: Date
        var lists: [String: [FFNFandom]]
    }

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ffn-fandoms.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
           Date().timeIntervalSince(snap.date) < 7 * 24 * 3600 {
            lists = snap.lists
        }
    }

    func fandoms(category: String, force: Bool = false) async throws -> [FFNFandom] {
        if !force, let cached = lists[category] { return cached }
        let result = try await FFNService.fandoms(category: category)
        lists[category] = result
        save()
        return result
    }

    /// Lädt alle Kategorien, die noch fehlen (nacheinander, mit den üblichen Pausen).
    func loadAll() async {
        guard !isLoadingAll else { return }
        isLoadingAll = true
        defer { isLoadingAll = false }
        for c in FFNService.categories where lists[c.id] == nil {
            _ = try? await fandoms(category: c.id)
        }
    }

    /// Alle Fandoms aller Kategorien (für den „Alle“-Chip), doppelte Crossover-Einträge nur einmal.
    var allFandoms: [FFNFandom] {
        var seen = Set<String>()
        return FFNService.categories.flatMap { lists[$0.id] ?? [] }.filter { seen.insert($0.path).inserted }
    }

    /// Kategorie eines Fandoms (aus dem Pfad „/anime/Naruto/“).
    func category(of fandom: FFNFandom) -> FFNCategory? {
        let id = fandom.path.split(separator: "/").first.map(String.init)
        return FFNService.categories.first { $0.id == id }
    }

    /// Treffer pro Kategorie, beliebteste zuerst.
    func search(_ query: String) -> [(category: FFNCategory, fandoms: [FFNFandom])] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return FFNService.categories.compactMap { c in
            let hits = (lists[c.id] ?? [])
                .filter { f in words.allSatisfy { f.name.lowercased().contains($0) } }
                .sorted { $0.countValue > $1.countValue }
            return hits.isEmpty ? nil : (c, Array(hits.prefix(25)))
        }
    }

    private func save() {
        let snap = Snapshot(date: Date(), lists: lists)
        try? JSONEncoder().encode(snap).write(to: Self.file, options: .atomic)
    }
}

// MARK: - Fandom-Übersicht

struct FFNBrowseView: View {
    @AppStorage("ffn.category") private var categoryID = "anime"
    @AppStorage("ffn.pinned") private var pinnedData: Data = Data()
    @AppStorage("ffn.savedFilters") private var savedData: Data = Data()
    @State private var store = FFNFandomStore.shared
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchText = ""
    @State private var sortByPopularity = true

    private static let allID = "all"
    private var isAll: Bool { categoryID == Self.allID }
    private var fandoms: [FFNFandom] { isAll ? store.allFandoms : store.lists[categoryID] ?? [] }
    private var isSearching: Bool { !searchText.trimmed.isEmpty }

    private var pinned: [FFNFandom] {
        (try? JSONDecoder().decode([FFNFandom].self, from: pinnedData)) ?? []
    }

    private var saved: [FFNFandom] {
        (try? JSONDecoder().decode([FFNFandom].self, from: savedData)) ?? []
    }

    private var visibleFandoms: [FFNFandom] {
        var list = fandoms
        if sortByPopularity { list.sort { $0.countValue > $1.countValue } }
        else { list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        return list
    }

    static func indexLetter(_ name: String) -> String {
        guard let c = name.folding(options: .diacriticInsensitive, locale: nil).uppercased().first, c.isLetter, c.isASCII else { return "#" }
        return String(c)
    }

    /// Erster Fandom je Buchstabe (alphabetisch) – Sprungziele für die A–Z-Leiste.
    private var letterAnchors: [(letter: String, id: String)] {
        var seen = Set<String>()
        return fandoms
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { f in
                let l = Self.indexLetter(f.name)
                return seen.insert(l).inserted ? (l, f.id) : nil
            }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if isSearching {
                    searchResults
                } else {
                    browseContent
                }
            }
            .overlay(alignment: .trailing) {
                if !isSearching && fandoms.count > 30 {
                    AlphabetIndexBar(letters: letterAnchors.map(\.letter)) { letter in
                        guard let target = letterAnchors.first(where: { $0.letter == letter })?.id else { return }
                        if sortByPopularity {
                            sortByPopularity = false
                            // Erst neu sortieren lassen, dann springen.
                            Task { @MainActor in proxy.scrollTo(target, anchor: .top) }
                        } else {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .themedBackground()
        .siteStatusBanner(.ffn)
        .navigationTitle("FanFiction.net")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Fandom suchen, z. B. Harry Potter")
        .overlay {
            if !isSearching && isLoading && fandoms.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Lade Fandoms …").font(.footnote).foregroundStyle(.secondary)
                }
            } else if !isSearching, let error, fandoms.isEmpty {
                ErrorBanner(message: error) { Task { await load(force: true) } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    FFNAccountView()
                } label: {
                    Label("Konto", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sortierung", selection: $sortByPopularity) {
                        Text("Nach Beliebtheit").tag(true)
                        Text("Alphabetisch").tag(false)
                    }
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: categoryID) { await load(force: false) }
        .task(id: isSearching) { if isSearching { await store.loadAll() } }
        .refreshable { await load(force: true) }
    }

    // MARK: Suche über alle Kategorien

    @ViewBuilder
    private var searchResults: some View {
        let groups = store.search(searchText.trimmed)
        if store.isLoadingAll {
            HStack(spacing: 10) {
                ProgressView()
                Text("Durchsuche alle Kategorien … \(store.lists.count)/\(FFNService.categories.count)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .themedRows(grouped: false)
        }
        ForEach(groups, id: \.category.id) { group in
            Section {
                ForEach(group.fandoms) { f in fandomRow(f) }
            } header: {
                Text(group.category.name)
            }
            .themedRows()
        }
        if groups.isEmpty && !store.isLoadingAll {
            ContentUnavailableView.search(text: searchText)
                .listRowBackground(Color.clear)
        }
        Section {
            NavigationLink {
                FFNKeywordSearchView(initialQuery: searchText.trimmed)
            } label: {
                Label("Geschichten mit „\(searchText.trimmed)“ suchen", systemImage: "text.magnifyingglass")
            }
        }
        .themedRows()
    }

    private func fandomRow(_ f: FFNFandom) -> some View {
        NavigationLink(value: f) {
            HStack {
                Text(f.name).lineLimit(2)
                Spacer()
                if !f.countText.isEmpty {
                    Text(f.countText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Stöbern

    @ViewBuilder
    private var browseContent: some View {
        Section {
            categoryBar
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }

        if !saved.isEmpty {
            Section("Gespeicherte Filter") {
                ForEach(saved) { f in
                    NavigationLink(value: f) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(f.name, systemImage: "line.3.horizontal.decrease.circle.fill")
                            if !f.countText.isEmpty {
                                Text(f.countText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    var list = saved
                    list.remove(atOffsets: idx)
                    savedData = (try? JSONEncoder().encode(list)) ?? Data()
                }
            }
            .themedRows()
        }

        if !pinned.isEmpty {
            Section("Gemerkte Fandoms") {
                ForEach(pinned) { f in
                    NavigationLink(value: f) { Label(f.name, systemImage: "star.fill") }
                }
            }
            .themedRows()
        }

        Section {
            NavigationLink {
                FFNKeywordSearchView()
            } label: {
                Label("Geschichten nach Stichwort suchen", systemImage: "text.magnifyingglass")
            }
        }
        .themedRows()

        Section {
            ForEach(visibleFandoms) { f in fandomRow(f) }
        } header: {
            HStack {
                Text(isAll ? String(localized: "Alle Kategorien") : FFNService.categories.first { $0.id == categoryID }?.name ?? "Fandoms")
                if isAll && store.isLoadingAll {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("\(store.lists.count)/\(FFNService.categories.count)").font(.caption.monospacedDigit())
                }
            }
        }
        .themedRows()
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassChip(title: String(localized: "Alle"), isSelected: isAll) {
                        withAnimation(.snappy) { categoryID = Self.allID }
                    }
                    ForEach(FFNService.categories) { c in
                        GlassChip(title: c.name, isSelected: c.id == categoryID) {
                            withAnimation(.snappy) { categoryID = c.id }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    private func load(force: Bool) async {
        if isAll {
            // Fehlende Kategorien nachladen; die schon geladenen erscheinen sofort.
            await store.loadAll()
            return
        }
        guard force || store.lists[categoryID] == nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            _ = try await store.fandoms(category: categoryID, force: force)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Geschichten eines Fandoms (mit den echten FFN-Filtern)

@MainActor
@Observable
final class FFNListModel {
    var baseURL: URL
    var currentURL: URL
    var stories: [RemoteStory] = []
    var filters: [FFNFilterSelect] = []
    /// Paare, die als Pairing gelten sollen (Namen wie „Hinata H.“) – FFN kennt nur ein Häkchen für alle,
    /// deshalb wird zusätzlich hier pro Paar gefiltert.
    var requiredPairs: [[String]] = []
    /// Welche Paare (1 = A+B, 2 = C+D) im Filter als Pairing markiert sind.
    var pairToggles: [Bool] = [false, false]
    /// Was FFN ohne Filter vorauswählt (z. B. „Rated K → T“) – zählt nicht als aktiver Filter.
    var defaults: [String: String] = [:]
    var page = 1
    var hasNext = false
    var isLoading = false
    var error: String?

    init(url: URL) {
        baseURL = url
        currentURL = url
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await FFNService.list(url: currentURL, page: 1)
            apply(result, replace: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasNext, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await FFNService.list(url: currentURL, page: page + 1)
            page += 1
            apply(result, replace: false)
        } catch {
            hasNext = false
        }
    }

    func applyFilters(_ values: [String: String], pairs: [Bool] = [false, false]) async {
        pairToggles = pairs
        requiredPairs = zip([("characterid1", "characterid2"), ("characterid3", "characterid4")], pairs).compactMap { names, on in
            guard on else { return nil }
            let a = optionText(names.0, values[names.0]), b = optionText(names.1, values[names.1])
            return [a, b].compactMap { $0 }.count == 2 ? [a!, b!] : nil
        }
        isLoading = true
        error = nil
        stories = []
        defer { isLoading = false }
        do {
            let result = try await FFNService.applyFilters(on: currentURL, values: values)
            currentURL = FFNService.setPage(result.url, page: 1)
            apply(result, replace: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetFilters() async {
        requiredPairs = []
        pairToggles = [false, false]
        currentURL = baseURL
        stories = []
        await load()
    }

    private func optionText(_ filter: String, _ value: String?) -> String? {
        guard let value, value != "0" else { return nil }
        return filters.first { $0.name == filter }?.options.first { $0.value == value }?.text
    }

    /// Geschichte enthält jedes geforderte Paar als Pairing ([A, B] auf FFN).
    private func matchesPairs(_ story: RemoteStory) -> Bool {
        requiredPairs.allSatisfy { pair in
            story.relationships.contains { rel in
                let parts = rel.components(separatedBy: "/").map(\.trimmed)
                return pair.allSatisfy(parts.contains)
            }
        }
    }

    private func apply(_ result: FFNListPage, replace: Bool) {
        let incoming = requiredPairs.isEmpty ? result.stories : result.stories.filter(matchesPairs)
        if replace {
            stories = incoming
            page = 1
        } else {
            let known = Set(stories.map(\.id))
            stories += incoming.filter { !known.contains($0.id) }
        }
        if !result.filters.isEmpty {
            filters = result.filters
            if defaults.isEmpty, currentURL == baseURL {
                defaults = Dictionary(result.filters.map { ($0.name, $0.selected) }, uniquingKeysWith: { a, _ in a })
            }
        }
        hasNext = result.hasNext && !result.stories.isEmpty
    }

    var activeFilterCount: Int {
        filters.filter { $0.selected != (defaults[$0.name] ?? $0.options.first?.value) }.count
    }
}

struct FFNStoryListView: View {
    let title: String
    let fandom: FFNFandom?
    @State private var model: FFNListModel
    @State private var showFilters = false
    @State private var showSave = false
    @State private var presetName = ""
    @AppStorage("ffn.pinned") private var pinnedData: Data = Data()
    @AppStorage("ffn.savedFilters") private var savedData: Data = Data()

    init(title: String, url: URL, fandom: FFNFandom? = nil) {
        self.title = title
        self.fandom = fandom
        _model = State(initialValue: FFNListModel(url: url))
    }

    private var pinned: [FFNFandom] { (try? JSONDecoder().decode([FFNFandom].self, from: pinnedData)) ?? [] }
    private var isPinned: Bool { fandom.map { f in pinned.contains { $0.path == f.path } } ?? false }

    var body: some View {
        List {
            ForEach(model.stories) { story in
                NavigationLink(value: story) { StoryRow(story: story) }
                    .remoteStoryActions(story)
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
        .siteStatusBanner(.ffn)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.isLoading && model.stories.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Lade von FanFiction.net …").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let error = model.error, model.stories.isEmpty {
                ErrorBanner(message: error) { Task { await model.load() } }
            } else if !model.isLoading && model.stories.isEmpty, let outage = SiteStatus.shared.outage(.ffn) {
                OutageEmptyView(site: .ffn, outage: outage) { Task { await model.load() } }
            } else if !model.isLoading && model.stories.isEmpty {
                ContentUnavailableView("Keine Geschichten", systemImage: "text.book.closed",
                                       description: Text("Mit diesen Filtern gibt es nichts."))
            }
        }
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let fandom {
                    Button(isPinned ? "Nicht mehr merken" : "Fandom merken", systemImage: isPinned ? "star.fill" : "star") {
                        var list = pinned
                        if isPinned { list.removeAll { $0.path == fandom.path } } else { list.append(fandom) }
                        pinnedData = (try? JSONEncoder().encode(list)) ?? Data()
                    }
                }
                Button {
                    showFilters = true
                } label: {
                    Label("Filter", systemImage: model.activeFilterCount > 0
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .disabled(model.filters.isEmpty)
                if model.activeFilterCount > 0 {
                    Button("Filter speichern", systemImage: "bookmark") {
                        presetName = title
                        showSave = true
                    }
                }
            }
        }
        .alert("Filter speichern", isPresented: $showSave) {
            TextField("Name", text: $presetName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") { saveFilters() }
        } message: {
            Text("Findest du im FanFiction-Tab unter „Gespeicherte Filter“ wieder.")
        }
        .sheet(isPresented: $showFilters) {
            FFNFilterSheet(filters: model.filters, pageURL: model.baseURL, pairs: model.pairToggles) { values, pairs in
                Task { await model.applyFilters(values, pairs: pairs) }
            } onReset: {
                Task { await model.resetFilters() }
            }
        }
        .task { if model.stories.isEmpty { await model.load() } }
    }

    /// Die Filter stecken komplett in der URL der Ergebnisseite – die wird gespeichert.
    private func saveFilters() {
        let name = presetName.trimmed
        guard !name.isEmpty else { return }
        var comps = URLComponents(url: model.currentURL, resolvingAgainstBaseURL: false)
        comps?.scheme = nil
        comps?.host = nil
        let path = comps?.string ?? model.currentURL.path
        let description = model.filters
            .filter { $0.selected != $0.options.first?.value }
            .compactMap { f in f.options.first { $0.value == f.selected }?.text }
            .joined(separator: " · ")
        var list = (try? JSONDecoder().decode([FFNFandom].self, from: savedData)) ?? []
        list.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        list.insert(FFNFandom(name: name, path: path, countText: description), at: 0)
        savedData = (try? JSONEncoder().encode(list)) ?? Data()
    }
}

// MARK: - Stichwortsuche

struct FFNKeywordSearchView: View {
    var initialQuery = ""
    @State private var query = ""
    @AppStorage("ffn.searchMatch") private var match: FFNService.SearchMatch = .title
    @State private var stories: [RemoteStory] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var searched = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(stories) { story in
                NavigationLink(value: story) { StoryRow(story: story) }
                    .remoteStoryActions(story)
            }
            .themedRows(grouped: false)
            if hasNext {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
                    .task { await search(page: page + 1) }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .siteStatusBanner(.ffn)
        .navigationTitle("FFN-Suche")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: match == .title ? String(localized: "Titel") : String(localized: "Titel oder Stichwort"))
        .searchScopes($match, activation: .onSearchPresentation) {
            ForEach(FFNService.SearchMatch.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .onSubmit(of: .search) { Task { await search(page: 1) } }
        .onChange(of: match) { if searched { Task { await search(page: 1) } } }
        .overlay {
            if isLoading && stories.isEmpty {
                ProgressView("Suche auf FanFiction.net …")
            } else if let error, stories.isEmpty {
                ErrorBanner(message: error) { Task { await search(page: 1) } }
            } else if searched && stories.isEmpty, let outage = SiteStatus.shared.outage(.ffn) {
                OutageEmptyView(site: .ffn, outage: outage) { Task { await search(page: 1) } }
            } else if searched && stories.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !searched {
                ContentUnavailableView("Stichwortsuche", systemImage: "text.magnifyingglass",
                                       description: Text("Durchsucht Titel und Zusammenfassungen auf FanFiction.net."))
            }
        }
        .task {
            if !initialQuery.isEmpty && !searched {
                query = initialQuery
                await search(page: 1)
            }
        }
    }

    private func search(page: Int) async {
        guard !query.trimmed.isEmpty, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false; searched = true }
        do {
            let result = try await FFNService.search(keywords: query, match: match, page: page)
            if page == 1 {
                stories = result.stories
            } else {
                let known = Set(stories.map(\.id))
                stories += result.stories.filter { !known.contains($0.id) }
            }
            self.page = page
            hasNext = result.hasNext && !result.stories.isEmpty
        } catch {
            if page == 1 { self.error = error.localizedDescription }
            hasNext = false
        }
    }
}

// MARK: - A–Z-Leiste

/// Buchstabenleiste am rechten Rand (wie in Kontakte), aus Liquid Glass.
/// Antippen oder darüberziehen springt zum Buchstaben; beim Ziehen erscheint er groß in einer Glasblase.
struct AlphabetIndexBar: View {
    let letters: [String]
    var onSelect: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var active: String?

    var body: some View {
        GeometryReader { geo in
            let rowHeight = min(16, (geo.size.height - 24) / CGFloat(max(letters.count, 1)))
            HStack(spacing: 8) {
                if let active {
                    Text(active)
                        .font(.title.weight(.bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    ForEach(letters, id: \.self) { l in
                        Text(l)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(active == l ? theme.primary : .secondary)
                            .frame(width: 22, height: rowHeight)
                    }
                }
                .padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let index = Int((value.location.y - 8) / rowHeight)
                            guard letters.indices.contains(index) else { return }
                            let letter = letters[index]
                            if letter != active {
                                withAnimation(.snappy(duration: 0.15)) { active = letter }
                                UISelectionFeedbackGenerator().selectionChanged()
                                onSelect(letter)
                            }
                        }
                        .onEnded { _ in withAnimation(.snappy) { active = nil } }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(width: 100)
        .frame(maxHeight: CGFloat(letters.count) * 16 + 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Alphabetischer Index")
    }
}
