import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum AppTab: Hashable {
    case library, ao3, ffn, books, search
}

struct RootView: View {
    @Environment(ReaderPresenter.self) private var reader
    @Environment(LibraryManager.self) private var library
    @Environment(\.modelContext) private var context
    @Environment(UpdateNotifier.self) private var notifier
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var fetcher = WebFetcher.shared
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = true

    @State private var tab: AppTab = .library
    @State private var ao3Path = NavigationPath()
    @State private var importError: String?

    var body: some View {
        @Bindable var reader = reader

        TabView(selection: $tab) {
            Tab("Bibliothek", systemImage: "books.vertical.fill", value: AppTab.library) {
                NavigationStack { LibraryView().babelDestinations() }
            }
            Tab("AO3", systemImage: "archivebox.fill", value: AppTab.ao3) {
                // Eigener Pfad: Die Filterwand schiebt die Ergebnisse als Wert auf den Stapel.
                // (Mit navigationDestination(item:) wurde die Liste beim Öffnen einer Story neu gebaut.)
                NavigationStack(path: $ao3Path) {
                    AO3FilterWallView(path: $ao3Path).babelDestinations()
                }
            }
            Tab("FFN", systemImage: "text.book.closed.fill", value: AppTab.ffn) {
                NavigationStack { FFNBrowseView().babelDestinations() }
            }
            Tab("Bücher", systemImage: "building.columns.fill", value: AppTab.books) {
                NavigationStack { BooksView().babelDestinations() }
            }
            Tab("Suchen", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { GlobalSearchView().babelDestinations() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            ContinueReadingAccessory()
        }
        // Oben statt unten: unten liegen Suchknöpfe, Weiterlesen-Leiste und Tab-Bar.
        .overlay(alignment: .top) {
            StatusToast()
                .padding(.top, 54)
                .allowsHitTesting(false)
        }
        .background(WebFetcherHost().frame(width: 1, height: 1).allowsHitTesting(false))
        .fullScreenCover(item: $reader.story) { story in
            ReaderView(story: story)
        }
        .sheet(isPresented: Binding(
            get: { fetcher.needsUserInteraction && self.reader.story == nil },
            set: { fetcher.needsUserInteraction = $0 }
        )) {
            ChallengeSheet()
        }
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "epub" else { return }
            Task {
                do {
                    _ = try await library.importEPUB(at: url, context: context)
                    tab = .library
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert("Import fehlgeschlagen", isPresented: .constant(importError != nil), presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { Text($0) }
        // Tippen auf „Neues Kapitel“-Mitteilung: Geschichte im Reader öffnen.
        .onChange(of: notifier.pendingStoryKey, initial: true) { _, key in
            guard let key else { return }
            notifier.pendingStoryKey = nil
            let descriptor = FetchDescriptor<Story>(predicate: #Predicate { $0.key == key })
            if let story = try? context.fetch(descriptor).first {
                tab = .library
                self.reader.open(story)
            }
        }
        // „In Babel öffnen“ aus dem Teilen-Menü: beim Zurückkommen abholen.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await ShareInbox.drain(library: library, context: context) } }
        }
        .task {
            library.pruneViewed(context: context)
            if checkUpdatesOnLaunch { await library.checkAllUpdates(context: context) }
            await FFNAccount.shared.syncIfDue(library: library, context: context)
        }
    }
}

/// Die "Weiterlesen"-Leiste über der Tab-Bar (Liquid-Glass-Accessory von iOS 26).
struct ContinueReadingAccessory: View {
    @Environment(ReaderPresenter.self) private var reader
    @Query(filter: #Predicate<Story> { $0.lastOpenedAt != nil }, sort: [SortDescriptor(\Story.lastOpenedAt, order: .reverse)])
    private var recent: [Story]
    @State private var speech = ReadAloudPlayer.shared

    var body: some View {
        if let story = speech.story {
            // Beim Vorlesen wird die Leiste zum Mini-Player.
            HStack(spacing: 12) {
                Button { reader.open(story) } label: {
                    HStack(spacing: 12) {
                        CoverView(story: story.asRemote, localCover: ContentStore.coverFileURL(story), width: 30, aspect: 1)
                            .padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(story.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Label(speech.chapterTitle, systemImage: "speaker.wave.2.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button { speech.toggle() } label: {
                    Group {
                        if speech.isLoading { ProgressView() }
                        else { Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isPlaying ? "Pause" : "Abspielen")
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
        } else if let story = recent.first {
            Button { reader.open(story) } label: {
                HStack(spacing: 12) {
                    // Quadratisch wie die Mini-Player-Cover in Apple Music, mit Abstand zur runden Kante.
                    CoverView(story: story.asRemote, localCover: ContentStore.coverFileURL(story), width: 30, aspect: 1)
                        .padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(story.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(story.title(ofChapter: story.currentChapter)) · \(Int(story.overallProgress * 100)) %")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "book")
                Text("Öffne eine Geschichte, um hier weiterzulesen").font(.footnote)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
        }
    }
}

/// Gemeinsame Navigationsziele für alle Tabs.
struct TagSearchRoute: Hashable {
    var tag: String
}

extension View {
    func babelDestinations() -> some View {
        self
            .navigationDestination(for: Story.self) { StoryDetailView(story: $0) }
            .navigationDestination(for: RemoteStory.self) { RemoteStoryDetail(remote: $0) }
            .navigationDestination(for: AO3SearchRoute.self) { AO3SearchView(initialFilters: $0.filters, title: $0.title) }
            .navigationDestination(for: AO3SeriesRoute.self) { AO3SeriesView(route: $0) }
            .navigationDestination(for: TagSearchRoute.self) { route in
                AO3SearchView(initialFilters: AO3Filters(otherTags: [route.tag]), title: route.tag)
            }
            .navigationDestination(for: FFNFandom.self) { FFNStoryListView(title: $0.name, url: $0.url, fandom: $0) }
    }
}

/// Wandelt ein Suchergebnis in eine (noch nicht gespeicherte) Story und zeigt die Detailseite.
struct RemoteStoryDetail: View {
    let remote: RemoteStory
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @State private var story: Story?

    var body: some View {
        Group {
            if let story { StoryDetailView(story: story) } else { ProgressView() }
        }
        .task { if story == nil { story = library.story(for: remote, context: context) } }
    }
}
