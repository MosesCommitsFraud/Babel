import SwiftUI

/// Reviews (FFN) bzw. Kommentare (AO3) einer Geschichte, seitenweise.
struct CommentsView: View {
    let story: Story
    @Environment(\.theme) private var theme
    @State private var comments: [StoryComment] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var didLoad = false

    private var title: String { story.source == .ffn ? String(localized: "Reviews") : String(localized: "Kommentare") }

    var body: some View {
        List {
            ForEach(comments) { comment in
                commentRow(comment)
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
            }
            if hasNext {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
                    .task { await load(page: page + 1) }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && comments.isEmpty {
                ProgressView("Lade \(title) …")
            } else if let error, comments.isEmpty {
                ErrorBanner(message: error) { Task { await load(page: 1) } }
            } else if didLoad && comments.isEmpty {
                ContentUnavailableView("Noch keine \(title)", systemImage: "text.bubble")
            }
        }
        .refreshable { await load(page: 1) }
        .task { if !didLoad { await load(page: 1) } }
    }

    private func commentRow(_ c: StoryComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if c.isReply {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text(c.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let chapter = c.chapter {
                    TagChip(text: String(localized: "Kap. \(chapter)"))
                }
                if let date = c.date {
                    Text(date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(c.text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(theme.card, in: .rect(cornerRadius: 16))
        .padding(.leading, c.isReply ? 24 : 0)
        .padding(.vertical, 2)
    }

    private func load(page: Int) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false; didLoad = true }
        do {
            let result = try await CommentsService.load(source: story.source, storyID: story.sourceID, page: page)
            if page == 1 { comments = result.comments } else { comments += result.comments }
            self.page = page
            hasNext = result.hasNext && !result.comments.isEmpty
        } catch {
            if page == 1 { self.error = error.localizedDescription }
            hasNext = false
        }
    }
}
