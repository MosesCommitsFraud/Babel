import SwiftUI
import SwiftData

/// Such-Tab: Bibliothek durchsuchen, Links einfügen, auf AO3/FFN weitersuchen.
struct GlobalSearchView: View {
    @Query private var allStories: [Story]
    @State private var query = ""
    @State private var showLink = false

    private var matches: [Story] {
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return allStories.filter { s in
            [[s.title, s.author], s.fandoms, s.relationships, s.characters, s.tags].joined().contains { $0.lowercased().contains(q) }
        }
        .sorted { a, b in
            if a.inLibrary != b.inLibrary { return a.inLibrary }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private var recent: [Story] {
        allStories.filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(15).map { $0 }
    }

    var body: some View {
        List {
            Group {
                if query.trimmed.isEmpty {
                    Section {
                        Button { showLink = true } label: {
                            Label("Link von AO3, FanFiction.net oder EPUB einfügen", systemImage: "link.badge.plus")
                        }
                    }
                    if !recent.isEmpty {
                        Section("Zuletzt geöffnet") {
                            ForEach(recent) { s in
                                NavigationLink(value: s) {
                                    StoryRow(story: s.asRemote, localCover: ContentStore.coverFileURL(s),
                                             progress: s.overallProgress, showSummary: false)
                                }
                            }
                        }
                    }
                } else {
                    Section("Weitersuchen") {
                        NavigationLink {
                            AO3SearchView(initialFilters: AO3Filters(query: query), title: "AO3: \(query)")
                        } label: {
                            Label("„\(query)“ auf AO3 suchen", systemImage: "archivebox")
                        }
                        NavigationLink {
                            FFNKeywordSearchView(initialQuery: query)
                        } label: {
                            Label("„\(query)“ auf FanFiction.net suchen", systemImage: "text.book.closed")
                        }
                    }
                    if !matches.isEmpty {
                        Section("In deiner Bibliothek & Verlauf") {
                            ForEach(matches) { s in
                                NavigationLink(value: s) {
                                    StoryRow(story: s.asRemote, localCover: ContentStore.coverFileURL(s),
                                             progress: s.hasStarted ? s.overallProgress : nil, showSummary: false)
                                }
                            }
                        }
                    }
                }
            }
            .themedRows()
        }
        .themedBackground()
        .navigationTitle("Suchen")
        .searchable(text: $query, prompt: "Bibliothek, AO3, FanFiction.net")
        .sheet(isPresented: $showLink) { LinkImportSheet() }
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
                        StoryRow(story: imported.asRemote, localCover: ContentStore.coverFileURL(imported), showSummary: false)
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
