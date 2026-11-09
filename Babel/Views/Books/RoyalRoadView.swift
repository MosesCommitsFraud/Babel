import SwiftUI

/// Web-Serien-Seiten im Bücher-Tab: Royal Road (Englisch) und Syosetu (Japanisch).
enum SerialSite: String, Hashable, CaseIterable, Sendable {
    case royalRoad, syosetu

    var title: String {
        switch self {
        case .royalRoad: "Royal Road"
        case .syosetu: "小説家になろう"
        }
    }

    var about: String {
        switch self {
        case .royalRoad: String(localized: "Web-Serien und Web Novels, laufend fortgesetzt.")
        case .syosetu: String(localized: "Syosetu: japanische Web Novels, von den Autor:innen selbst veröffentlicht.")
        }
    }

    var languages: [String] { self == .royalRoad ? ["en"] : ["ja"] }

    /// Listen der Seite: Kennung und Name.
    var lists: [(id: String, label: String)] {
        switch self {
        case .royalRoad: RoyalRoadService.List.allCases.map { ($0.rawValue, $0.label) }
        case .syosetu: SyosetuService.List.allCases.map { ($0.rawValue, $0.label) }
        }
    }

    func list(_ id: String, page: Int) async throws -> RoyalRoadService.Page {
        switch self {
        case .royalRoad: try await RoyalRoadService.list(RoyalRoadService.List(rawValue: id) ?? .trending, page: page)
        case .syosetu: try await SyosetuService.list(SyosetuService.List(rawValue: id) ?? .weekly, page: page)
        }
    }

    func search(_ query: String, page: Int) async throws -> RoyalRoadService.Page {
        switch self {
        case .royalRoad: try await RoyalRoadService.search(query, page: page)
        case .syosetu: try await SyosetuService.search(query, page: page)
        }
    }
}

/// Eine Web-Serien-Seite: ihre Listen als Chips, dazu die Suche.
struct SerialSiteView: View {
    let site: SerialSite
    var initialQuery = ""

    @State private var listID = ""
    @State private var query = ""
    @State private var submitted = ""
    @State private var stories: [RemoteStory] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var didStart = false
    @State private var loadTask: Task<Void, Never>?

    private var storageKey: String { "serial.list.\(site.rawValue)" }

    var body: some View {
        List {
            if submitted.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(site.lists, id: \.id) { item in
                                    GlassChip(title: item.label, isSelected: listID == item.id) {
                                        withAnimation(.snappy) { listID = item.id }
                                        UserDefaults.standard.set(item.id, forKey: storageKey)
                                        reload()
                                    }
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
            }

            Section {
                ForEach(stories) { story in
                    NavigationLink(value: story) { StoryRow(story: story) }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .remoteStoryActions(story)
                        .loadsMore(near: story, in: stories) { if hasNext && !isLoading { await load(page: page + 1) } }
                }
                if hasNext {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .task { if !isLoading { await load(page: page + 1) } }
                }
            }
            .themedRows(grouped: false)
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle(site.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titel suchen")
        .onSubmit(of: .search) {
            submitted = query.trimmed
            reload()
        }
        .onChange(of: query) { old, new in
            if !old.isEmpty && new.isEmpty && !submitted.isEmpty { submitted = ""; reload() }
        }
        .overlay {
            if isLoading && stories.isEmpty {
                ProgressView("Lade Geschichten …")
            } else if let error, stories.isEmpty {
                ErrorBanner(message: error) { reload() }
            } else if !isLoading && stories.isEmpty && didStart {
                ContentUnavailableView("Keine Geschichten", systemImage: "book.closed", description: Text("Versuch es mit einem anderen Titel."))
            }
        }
        .refreshable { await load(page: 1) }
        .task {
            guard !didStart else { return }
            let saved = UserDefaults.standard.string(forKey: storageKey) ?? ""
            listID = site.lists.contains { $0.id == saved } ? saved : (site.lists.first?.id ?? "")
            if !initialQuery.isEmpty {
                query = initialQuery
                submitted = initialQuery
            }
            await load(page: 1)
            didStart = true
        }
    }

    private func reload() {
        loadTask?.cancel()
        stories = []
        loadTask = Task { await load(page: 1) }
    }

    private func load(page: Int) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let search = submitted
        let current = listID
        do {
            let result = search.isEmpty ? try await site.list(current, page: page) : try await site.search(search, page: page)
            guard !Task.isCancelled, search == submitted, current == listID else { return }
            if page == 1 {
                stories = result.stories
            } else {
                let known = Set(stories.map(\.id))
                stories += result.stories.filter { !known.contains($0.id) }
            }
            self.page = page
            hasNext = result.hasNext && !result.stories.isEmpty
        } catch {
            guard !Task.isCancelled else { return }
            if page == 1 { stories = []; self.error = error.localizedDescription }
            hasNext = false
        }
    }
}

/// Ein OPDS-Katalog oder einer seiner Unterkataloge: Ordner führen tiefer, Bücher öffnen die Detailseite.
struct OPDSFeedView: View {
    let title: String
    let url: URL

    @State private var feed: OPDSFeed?
    @State private var entries: [OPDSFeed.Entry] = []
    @State private var next: URL?
    @State private var hidden = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var query = ""
    @State private var searchURL: URL?
    @State private var loadTask: Task<Void, Never>?

    private var canSearch: Bool { feed?.searchTemplate != nil || feed?.searchDescription != nil }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    switch entry {
                    case .book(let book):
                        NavigationLink(value: book) { StoryRow(story: book) }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .remoteStoryActions(book)
                            .loadsMore(near: entry, in: entries) { await loadNext() }
                    case .navigation(let name, let subtitle, let target):
                        NavigationLink(value: BookRoute.feed(title: name, url: target)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.body.weight(.medium))
                                if !subtitle.isEmpty {
                                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if next != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .task { await loadNext() }
                }
            } footer: {
                if hidden > 0 {
                    Text("\(hidden) Einträge ohne EPUB sind ausgeblendet.")
                }
            }
            .themedRows(grouped: false)
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(OptionalSearch(isOn: canSearch, text: $query) { search() })
        .onChange(of: query) { old, new in
            if !old.isEmpty && new.isEmpty && searchURL != nil { searchURL = nil; reload() }
        }
        .overlay {
            if isLoading && entries.isEmpty {
                ProgressView("Lade Katalog …")
            } else if let error, entries.isEmpty {
                ErrorBanner(message: error) { reload() }
            } else if !isLoading && entries.isEmpty && feed != nil {
                ContentUnavailableView("Nichts gefunden", systemImage: "books.vertical",
                                       description: Text(hidden > 0 ? "Hier gibt es nur Einträge ohne EPUB." : "Dieser Katalog ist hier leer."))
            }
        }
        .refreshable { await load() }
        .task { if feed == nil { await load() } }
    }

    private func reload() {
        loadTask?.cancel()
        entries = []
        loadTask = Task { await load() }
    }

    private func search() {
        let text = query.trimmed
        guard !text.isEmpty, let feed else { return }
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            defer { isLoading = false }
            do {
                guard let url = try await OPDSService.searchURL(feed, query: text) else { return }
                searchURL = url
                entries = []
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await OPDSService.feed(searchURL ?? url)
            guard !Task.isCancelled else { return }
            // Die Suche des Katalogs steht auf seiner Startseite – beim Anzeigen von Treffern behalten.
            if searchURL == nil || feed == nil { feed = result }
            entries = result.entries
            next = result.next
            hidden = result.hiddenCount
        } catch {
            guard !Task.isCancelled else { return }
            entries = []
            next = nil
            self.error = error.localizedDescription
        }
    }

    private func loadNext() async {
        guard let url = next, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await OPDSService.feed(url)
            let known = Set(entries.map(\.id))
            let fresh = result.entries.filter { !known.contains($0.id) }
            entries += fresh
            hidden += result.hiddenCount
            // Liefert eine Seite nichts Neues, ist Schluss – manche Kataloge verweisen im Kreis.
            next = fresh.isEmpty ? nil : result.next
        } catch {
            next = nil
        }
    }
}

/// Suchfeld nur, wenn der Katalog eine Suche anbietet.
private struct OptionalSearch: ViewModifier {
    let isOn: Bool
    @Binding var text: String
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        if isOn {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Im Katalog suchen")
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}
