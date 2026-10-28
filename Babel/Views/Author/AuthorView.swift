import SwiftUI

/// Seite einer Autorin / eines Autors: Profil, eigene Geschichten und Favoriten bzw. AO3-Lesezeichen.
struct AuthorView: View {
    let source: StorySource
    let name: String
    let url: URL

    private enum Tab: Hashable { case stories, favorites }

    @Environment(\.openURL) private var openURL
    @State private var profile: AuthorProfile?
    @State private var tab: Tab = .stories
    @State private var stories: [RemoteStory] = []
    @State private var favorites: [RemoteStory] = []
    @State private var nextPage: [Tab: Int] = [:]
    @State private var isLoading = false
    @State private var error: String?
    @State private var showFullBio = false

    private var ao3User: String? { source == .ao3 ? AO3Service.username(from: url) : nil }
    private var visible: [RemoteStory] { tab == .stories ? stories : favorites }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .themedRows(grouped: false)

            ForEach(visible) { story in
                NavigationLink {
                    RemoteStoryDetail(remote: story)
                } label: {
                    StoryRow(story: story)
                }
                .remoteStoryActions(story)
            }
            .themedRows(grouped: false)

            if nextPage[tab] != nil {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
                    .task(id: tab) { await loadMore() }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle(profile?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && profile == nil {
                ProgressView("Lade Profil …")
            } else if let error, profile == nil {
                ErrorBanner(message: error) { Task { await load() } }
            } else if profile != nil && visible.isEmpty && nextPage[tab] == nil {
                ContentUnavailableView(tab == .stories ? "Keine Geschichten" : "Keine Einträge", systemImage: "tray")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Im Browser öffnen", systemImage: "safari") { openURL(url) }
            }
        }
        .task { if profile == nil { await load() } }
    }

    // MARK: Kopf

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(source.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile?.name ?? name).font(.title3.weight(.bold))
                    HStack(spacing: 6) {
                        TagChip(text: source.shortLabel, tint: source.tint, symbol: source.symbol)
                        if let joined = profile?.joined {
                            TagChip(text: "seit \(joined.formatted(.dateTime.month(.abbreviated).year()))", symbol: "calendar")
                        }
                    }
                }
            }
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(showFullBio ? nil : 4)
                    .onTapGesture { withAnimation(.snappy) { showFullBio.toggle() } }
            }
            if profile != nil {
                GlassSegmented(options: [
                    (Tab.stories, label(source == .ao3 ? "Werke" : "Geschichten", profile?.storyCount)),
                    (Tab.favorites, label(source == .ao3 ? "Lesezeichen" : "Favoriten", profile?.favoriteCount)),
                ], selection: $tab)
            }
        }
        .padding(.vertical, 6)
    }

    private func label(_ text: String, _ count: Int?) -> String {
        count.map { "\(text) \($0)" } ?? text
    }

    // MARK: Laden

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            switch source {
            case .ffn:
                let p = try await FFNService.authorProfile(url: url)
                stories = p.stories
                favorites = p.favorites
                profile = p
            case .ao3:
                guard let user = ao3User else { throw BabelError.invalidLink }
                profile = try await AO3Service.authorProfile(user: user)
                nextPage = [.stories: 1, .favorites: 1]
            case .gutenberg, .epub:
                throw BabelError.unsupported(url.host ?? "")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// AO3 lädt Werke und Lesezeichen seitenweise nach.
    private func loadMore() async {
        guard let user = ao3User, let page = nextPage[tab] else { return }
        let current = tab
        do {
            let result = try await AO3Service.authorList(current == .stories ? .works : .bookmarks, user: user, page: page)
            if current == .stories { stories += result.works.filter { w in !stories.contains { $0.id == w.id } } }
            else { favorites += result.works.filter { w in !favorites.contains { $0.id == w.id } } }
            nextPage[current] = result.hasNext && !result.works.isEmpty ? page + 1 : nil
        } catch {
            nextPage[current] = nil
            self.error = error.localizedDescription
        }
    }
}
