import SwiftUI

/// Navigationsziel: eine AO3-Serie.
struct AO3SeriesRoute: Hashable {
    var id: String
    var name: String
}

/// Die Werke einer AO3-Serie in Lesereihenfolge.
struct AO3SeriesView: View {
    let route: AO3SeriesRoute

    @State private var series: AO3Service.Series?
    @State private var works: [RemoteStory] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if let series, !series.summary.isEmpty || !series.creator.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        if !series.creator.isEmpty {
                            Text(series.creator).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        }
                        if !series.summary.isEmpty { Text(series.summary).font(.callout) }
                        if let words = series.words, let count = series.workCount {
                            Text("\(count) Werke · \(StoryRow.wordsShort(words))\(series.isComplete ? " · " + String(localized: "Abgeschlossen") : "")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowSeparator(.hidden)
                }
                .themedRows(grouped: false)
            }
            Section {
                ForEach(works) { work in
                    NavigationLink(value: work) { StoryRow(story: work) }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .remoteStoryActions(work)
                        .loadsMore(near: work, in: works) { if hasNext && !isLoading { await load(page: page + 1) } }
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
        .navigationTitle(series?.title.isEmpty == false ? series!.title : route.name)
        .navigationBarTitleDisplayMode(.inline)
        .siteStatusBanner(.ao3)
        .overlay {
            if isLoading && works.isEmpty {
                ProgressView("Lade Serie …")
            } else if let error, works.isEmpty {
                ErrorBanner(message: error) { Task { await load(page: 1) } }
            }
        }
        .refreshable { await load(page: 1, fresh: 0) }
        .task { if works.isEmpty { await load(page: 1) } }
    }

    private func load(page: Int, fresh: TimeInterval = 300) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await AO3Service.series(id: route.id, page: page, fresh: fresh)
            if page == 1 {
                series = result
                works = result.works
            } else {
                let known = Set(works.map(\.id))
                works += result.works.filter { !known.contains($0.id) }
            }
            self.page = page
            hasNext = result.hasNext && !result.works.isEmpty
        } catch {
            if page == 1 { self.error = error.localizedDescription }
            hasNext = false
        }
    }
}
