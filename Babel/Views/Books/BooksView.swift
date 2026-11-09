import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Wohin der Bücher-Tab führt.
enum BookRoute: Hashable {
    case library(BookLibrary, query: String = "")
    case serial(SerialSite, query: String = "")
    case feed(title: String, url: URL)
}

/// Eine Reihe auf der Startseite: Quelle mit ein paar Büchern zum Hineinschauen.
struct BookShelf: Identifiable, Hashable {
    enum Kind: Hashable {
        case serial(SerialSite)
        case library(BookLibrary)
        case catalog(OPDSCatalog)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .serial(let site): site == .royalRoad ? "royalroad" : site.rawValue
        case .library(let library): "library.\(library.rawValue)"
        case .catalog(let catalog): "catalog.\(catalog.id)"
        }
    }

    var title: String {
        switch kind {
        case .serial(let site): site.title
        case .library(let library): library.title
        case .catalog(let catalog): catalog.title
        }
    }

    var about: String {
        switch kind {
        case .serial(let site): site.about
        case .library(let library): library.about
        case .catalog(let catalog): catalog.about
        }
    }

    var route: BookRoute {
        switch kind {
        case .serial(let site): .serial(site)
        case .library(let library): .library(library)
        case .catalog(let catalog): .feed(title: catalog.title, url: catalog.url)
        }
    }

    /// Sprachen, in denen diese Quelle Bücher hat – leer = viele oder unbekannt.
    var languages: [String] {
        switch kind {
        case .serial(let site): site.languages
        case .library(let library): library.supportsLanguage ? [] : ["en"]
        case .catalog(let catalog): catalog.languages
        }
    }

    /// Hat die Quelle etwas in den gewählten Lesesprachen? (Leere Auswahl = alle Sprachen.)
    func offers(_ codes: [String]) -> Bool {
        codes.isEmpty || languages.isEmpty || languages.contains { codes.contains($0) }
    }

    func load(languages codes: [String]) async throws -> [RemoteStory] {
        try await fetch(query: "", languages: codes)
    }

    func search(_ query: String, languages codes: [String]) async throws -> [RemoteStory] {
        try await fetch(query: query, languages: codes)
    }

    private func fetch(query: String, languages codes: [String]) async throws -> [RemoteStory] {
        switch kind {
        case .serial(let site):
            return query.isEmpty
                ? try await site.list(site.lists.first?.id ?? "", page: 1).stories
                : try await site.search(query, page: 1).stories
        case .library(let library):
            // Die Bibliotheken filtern je Abfrage nach einer Sprache: je Sprache einmal fragen und reihum mischen.
            let wanted = library.supportsLanguage ? Array(codes.prefix(3)) : []
            var lists: [[RemoteStory]] = []
            var failure: Error?
            for code in wanted.isEmpty ? [""] : wanted {
                var filters = GutenbergFilters()
                filters.query = query
                filters.language = code
                do { lists.append(try await library.search(filters, page: 1).books) } catch { failure = error }
                try Task.checkCancellation()
            }
            // Nur wenn gar keine Sprache etwas geliefert hat, ist es ein Fehler.
            if lists.isEmpty, let failure { throw failure }
            var merged: [RemoteStory] = []
            var seen: Set<String> = []
            for i in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where i < list.count && seen.insert(list[i].id).inserted { merged.append(list[i]) }
            }
            return merged
        case .catalog(let catalog):
            let books: [RemoteStory]
            if query.isEmpty {
                books = try await OPDSService.showcase(catalog)
            } else {
                let root = try await OPDSService.feed(catalog.url)
                guard let url = try await OPDSService.searchURL(root, query: query) else { return [] }
                books = try await OPDSService.feed(url).books
            }
            return books.filter { BookLanguages.matches($0, codes) }
        }
    }
}

/// Lädt die Reihen der Startseite und merkt sie sich (Speicher + Caches/Shelves, 12 Stunden frisch),
/// damit der Tab sofort gefüllt aufgeht.
@MainActor
@Observable
final class BookShelfStore {
    static let shared = BookShelfStore()

    private(set) var books: [String: [RemoteStory]] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    @ObservationIgnored private var loadedFor: [String: String] = [:]

    private static let fresh: TimeInterval = 12 * 3600
    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Shelves", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private struct Saved: Codable { var date: Date; var books: [RemoteStory] }

    private static func file(_ key: String) -> URL {
        folder.appendingPathComponent(String(key.stableHash) + ".json")
    }

    func load(_ shelf: BookShelf, languages: [String], force: Bool = false) async {
        let language = languages.joined(separator: ",")
        let key = shelf.id + "|" + language
        // Je Sprachauswahl eine Ladung – ein Wechsel der Sprache darf nicht an der alten hängen bleiben.
        guard !loading.contains(key) else { return }
        // Andere Sprachauswahl: Die Reihe gehört zu einer anderen Abfrage.
        if loadedFor[shelf.id] != language {
            loadedFor[shelf.id] = language
            books[shelf.id] = nil
            loadedAt[shelf.id] = nil
        }
        if books[shelf.id] == nil || loadedAt[shelf.id] == nil {
            let file = Self.file(key)
            let saved = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
            }.value
            if let saved {
                books[shelf.id] = saved.books
                loadedAt[shelf.id] = saved.date
            }
        }
        if !force, let date = loadedAt[shelf.id], Date().timeIntervalSince(date) < Self.fresh, books[shelf.id]?.isEmpty == false { return }
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            let result = Array(try await shelf.load(languages: languages).prefix(14))
            guard loadedFor[shelf.id] == language else { return }
            books[shelf.id] = result
            errors[shelf.id] = nil
            loadedAt[shelf.id] = .now
            let file = Self.file(key)
            let saved = Saved(date: .now, books: result)
            Task.detached(priority: .utility) { try? JSONEncoder().encode(saved).write(to: file, options: .atomic) }
        } catch {
            // Abgebrochen (Sprache gewechselt, Tab verlassen) ist kein Fehler.
            guard !(error is CancellationError), !Task.isCancelled, loadedFor[shelf.id] == language else { return }
            // Der letzte Stand bleibt stehen – eine Fehlermeldung gibt es nur, wenn gar nichts da ist.
            if books[shelf.id]?.isEmpty != false { errors[shelf.id] = error.localizedDescription }
        }
    }

    func forget(_ shelf: BookShelf) {
        books[shelf.id] = nil
        loadedAt[shelf.id] = nil
        errors[shelf.id] = nil
    }
}

/// Bücher-Tab: alle Quellen auf einen Blick – je Quelle eine Reihe mit Büchern, Tippen auf den Namen öffnet die Quelle.
/// Die Suche oben sucht in allen Quellen zugleich.
struct BooksView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @Environment(\.theme) private var theme
    @AppStorage(OPDSCatalogStore.key) private var catalogData: Data = Data()
    @AppStorage(BookLanguages.key) private var storedLanguages = ""
    @AppStorage(StoryLanguage.key) private var readingLanguage = ""
    @Environment(\.layoutClass) private var layout

    @State private var store = BookShelfStore.shared
    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [String: [RemoteStory]] = [:]
    @State private var searching: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var showAddCatalog = false
    @State private var message: String?

    private var catalogs: [OPDSCatalog] { OPDSCatalogStore.decode(catalogData) }

    /// Lesesprachen (ISO, klein); leer = alle. Folgt der Lesesprache aus den Einstellungen, bis hier gewählt wird.
    private var languages: [String] { BookLanguages.codes(stored: storedLanguages, reading: readingLanguage) }

    // Quellen ohne Bücher in den gewählten Sprachen erscheinen gar nicht erst.
    private var serials: [BookShelf] { SerialSite.allCases.map { BookShelf(kind: .serial($0)) }.filter { $0.offers(languages) } }
    private var libraries: [BookShelf] { BookLibrary.allCases.map { BookShelf(kind: .library($0)) }.filter { $0.offers(languages) } }
    private var catalogShelves: [BookShelf] { catalogs.map { BookShelf(kind: .catalog($0)) } }
    private var allShelves: [BookShelf] { serials + libraries + catalogShelves.filter { $0.offers(languages) } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                languageFilter
                if submitted.isEmpty {
                    if !serials.isEmpty { group(String(localized: "Web-Serien"), serials) }
                    if !libraries.isEmpty { group(String(localized: "Freie Bücher"), libraries) }
                    catalogGroup
                } else {
                    searchResults
                }
            }
            .padding(.vertical, 12)
        }
        .themedBackground()
        .navigationTitle("Bücher")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "In allen Quellen suchen")
        .onSubmit(of: .search) { search() }
        .onChange(of: query) { _, new in
            if new.trimmed.isEmpty { searchTask?.cancel(); submitted = "" }
        }
        .refreshable {
            await withTaskGroup(of: Void.self) { group in
                let languages = languages
                for shelf in allShelves { group.addTask { await store.load(shelf, languages: languages, force: true) } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("EPUB importieren", systemImage: "doc.badge.plus") { showImporter = true }
                    Button("Katalog hinzufügen", systemImage: "plus.rectangle.on.folder") { showAddCatalog = true }
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
            }
        }
        .navigationDestination(for: BookRoute.self) { route in
            switch route {
            case .library(let library, let query): BookSourceView(bookLibrary: library, initialQuery: query)
            case .serial(let site, let query): SerialSiteView(site: site, initialQuery: query)
            case .feed(let title, let url): OPDSFeedView(title: title, url: url)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var ok = 0
                var failures: [String] = []
                for url in urls {
                    do { _ = try await library.importEPUB(at: url, context: context); ok += 1 }
                    catch { failures.append(error.localizedDescription) }
                }
                message = failures.isEmpty ? String(localized: "\(ok) Buch/Bücher in deine Bibliothek gelegt.") : failures.joined(separator: "\n")
            }
        }
        .sheet(isPresented: $showAddCatalog) {
            AddCatalogSheet(existing: catalogs) { catalog in
                catalogData = OPDSCatalogStore.encode(catalogs + [catalog])
            }
        }
        .alert("Import", isPresented: .constant(message != nil), presenting: message) { _ in
            Button("OK") { message = nil }
        } message: { Text($0) }
    }

    // MARK: Sprache

    /// Filter oben: in welchen Sprachen Bücher gezeigt werden.
    private var languageFilter: some View {
        let selected = languages
        return Menu {
            Toggle("Alle Sprachen", isOn: Binding(get: { selected.isEmpty }, set: { if $0 { storedLanguages = BookLanguages.allValue } }))
            Divider()
            ForEach(BookLanguages.options) { option in
                Toggle(option.name, isOn: Binding(
                    get: { selected.contains(option.code) },
                    set: { on in
                        var codes = selected
                        if on { codes.append(option.code) } else { codes.removeAll { $0 == option.code } }
                        storedLanguages = BookLanguages.stored(codes)
                    }))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(languageLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal)
        .accessibilityLabel("Sprachen der Bücher")
        .accessibilityValue(languageLabel)
        .onChange(of: languages) { _, _ in if !submitted.isEmpty { search() } }
    }

    private var languageLabel: String {
        let names = languages.compactMap { code in BookLanguages.options.first { $0.code == code }?.name }
        if names.isEmpty { return String(localized: "Alle Sprachen") }
        return names.count > 3 ? String(localized: "\(names.count) Sprachen") : names.joined(separator: ", ")
    }

    // MARK: Startseite

    private func group(_ title: String, _ shelves: [BookShelf]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            groupTitle(title)
            ForEach(shelves) { shelf in
                BookShelfRow(shelf: shelf, languages: languages)
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.bold))
            .padding(.horizontal)
            .accessibilityAddTraits(.isHeader)
    }

    private var catalogGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            groupTitle(String(localized: "Kataloge"))
            ForEach(catalogShelves) { shelf in
                if shelf.offers(languages) {
                    BookShelfRow(shelf: shelf, languages: languages)
                        .contextMenu {
                            Button("Katalog entfernen", systemImage: "trash", role: .destructive) { remove(shelf) }
                        }
                } else {
                    // Nicht stillschweigend verstecken: Der Katalog gehört dem Nutzer.
                    NavigationLink(value: shelf.route) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shelf.title).font(.headline)
                                Text("Nicht in deinen Lesesprachen").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .contextMenu {
                        Button("Katalog entfernen", systemImage: "trash", role: .destructive) { remove(shelf) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Kataloge sind Bücherlisten im offenen OPDS-Format: von Bibliotheken, Verlagen oder deinem eigenen Server (Calibre-Web, Kavita …).")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Katalog hinzufügen", systemImage: "plus") { showAddCatalog = true }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal)
        }
    }

    private func remove(_ shelf: BookShelf) {
        guard case .catalog(let catalog) = shelf.kind else { return }
        // Auch ein leeres Ergebnis speichern – sonst käme der Startkatalog wieder.
        let left = catalogs.filter { $0.id != catalog.id }
        catalogData = left.isEmpty ? Data("[]".utf8) : OPDSCatalogStore.encode(left)
        store.forget(shelf)
    }

    // MARK: Suche in allen Quellen

    private func search() {
        let text = query.trimmed
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        submitted = text
        results = [:]
        let shelves = allShelves
        let languages = languages
        searching = Set(shelves.map(\.id))
        searchTask = Task {
            await withTaskGroup(of: (String, [RemoteStory]).self) { group in
                for shelf in shelves {
                    group.addTask { (shelf.id, (try? await shelf.search(text, languages: languages)) ?? []) }
                }
                for await (id, found) in group {
                    guard !Task.isCancelled, submitted == text else { return }
                    results[id] = found
                    searching.remove(id)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let shelves = allShelves
        let withHits = shelves.filter { results[$0.id]?.isEmpty == false }
        ForEach(withHits) { shelf in
            VStack(alignment: .leading, spacing: 4) {
                NavigationLink(value: searchRoute(shelf)) {
                    HStack(spacing: 6) {
                        Text(shelf.title).font(.title3.weight(.bold))
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                ForEach((results[shelf.id] ?? []).prefix(4)) { book in
                    NavigationLink(value: book) {
                        StoryRow(story: book, showSummary: false)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { BookTileMenu(book: book) }
                    Divider().padding(.leading)
                }
            }
        }
        if !searching.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Suche in \(searching.count) Quellen …").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, withHits.isEmpty ? 60 : 0)
        } else if withHits.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Keine Treffer für „\(submitted)“").font(.title3.weight(.bold))
                Text("Prüfe die Schreibweise oder versuche es mit anderen Wörtern.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 60)
        }
    }

    /// „Alle Treffer“: die Quelle mit demselben Suchbegriff öffnen.
    private func searchRoute(_ shelf: BookShelf) -> BookRoute {
        switch shelf.kind {
        case .serial(let site): .serial(site, query: submitted)
        case .library(let library): .library(library, query: submitted)
        case .catalog(let catalog): .feed(title: catalog.title, url: catalog.url)
        }
    }
}

/// Eine Quelle auf der Startseite: Name und Beschreibung (öffnet die Quelle), darunter Bücher zum Durchwischen.
private struct BookShelfRow: View {
    let shelf: BookShelf
    let languages: [String]
    @State private var store = BookShelfStore.shared
    @Environment(\.layoutClass) private var layout

    /// Größere Cover, wo Platz ist (Falt-iPhone, iPad).
    private var tileWidth: CGFloat { layout == .wide ? 150 : (layout == .medium ? 116 : 96) }

    var body: some View {
        let books = store.books[shelf.id] ?? []
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: shelf.route) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(shelf.title).font(.headline)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    if !shelf.about.isEmpty {
                        Text(shelf.about).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if !books.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(books) { book in
                            NavigationLink(value: book) { BookTile(book: book, width: tileWidth) }
                                .buttonStyle(.plain)
                                .contextMenu { BookTileMenu(book: book) }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            } else if let error = store.errors[shelf.id] {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Nochmal") { Task { await store.load(shelf, languages: languages, force: true) } }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal)
            } else {
                // Platzhalter in der Höhe der Bücher – beim Laden springt die Seite nicht.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 11).fill(.quaternary).frame(width: tileWidth, height: tileWidth * 1.5)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                .disabled(true)
                .frame(height: tileWidth * 1.5 + 56, alignment: .top)
            }
        }
        .task(id: languages) { await store.load(shelf, languages: languages) }
    }
}

/// Ein Buch in einer Reihe: Cover, Titel, Autor:in.
private struct BookTile: View {
    let book: RemoteStory
    var width: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(story: book, width: width)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if !book.author.isEmpty {
                    Text(book.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .top)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Kontextmenü eines Buchs außerhalb von Listen (dort gibt es Wischgesten über `remoteStoryActions`).
private struct BookTileMenu: View {
    let book: RemoteStory
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library

    var body: some View {
        Button("In die Bibliothek", systemImage: "bookmark") {
            let story = library.story(for: book, context: context)
            library.addToLibrary(story, context: context)
            library.updateMessage = String(localized: "„\(book.title)“ in der Bibliothek")
        }
        Button("Herunterladen (offline)", systemImage: "arrow.down.circle") {
            library.showProgress(String(localized: "Lade „\(book.title)“ …"))
            Task {
                do {
                    try await library.download(book, context: context)
                    library.updateMessage = String(localized: "„\(book.title)“ offline gespeichert")
                } catch {
                    library.updateMessage = String(localized: "Download fehlgeschlagen: \(error.localizedDescription)")
                }
            }
        }
        if book.url.scheme?.hasPrefix("http") == true { ShareLink(item: book.url) }
    }
}

/// Katalog per Adresse hinzufügen oder aus den Vorschlägen wählen. Die Adresse wird geprüft, bevor sie gespeichert wird.
struct AddCatalogSheet: View {
    let existing: [OPDSCatalog]
    var onAdd: (OPDSCatalog) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isChecking = false
    @State private var error: String?

    private var suggestions: [OPDSCatalog] {
        OPDSCatalog.suggestions.filter { s in !existing.contains { $0.id == s.id } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { check() }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Adresse des Katalogs")
                } footer: {
                    Text("OPDS-Adresse, zum Beispiel von deinem Calibre-Web-Server (endet oft auf /opds). Kataloge mit Anmeldung gehen noch nicht.")
                }
                .themedRows()

                if !suggestions.isEmpty {
                    Section("Vorschläge") {
                        ForEach(suggestions) { catalog in
                            Button {
                                onAdd(catalog)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(catalog.title).foregroundStyle(.primary)
                                    Text(catalog.about).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .themedRows()
                }
            }
            .themedBackground()
            .navigationTitle("Katalog hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("Hinzufügen", systemImage: "checkmark") { check() }
                            .disabled(address.trimmed.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func check() {
        var text = address.trimmed
        guard !text.isEmpty, !isChecking else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else {
            error = String(localized: "Das ist keine gültige Adresse.")
            return
        }
        if existing.contains(where: { $0.url == url }) {
            error = String(localized: "Diesen Katalog hast du schon.")
            return
        }
        isChecking = true
        error = nil
        Task {
            defer { isChecking = false }
            do {
                let feed = try await OPDSService.feed(url)
                onAdd(OPDSCatalog(title: feed.title.isEmpty ? (url.host ?? text) : feed.title, url: url))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
