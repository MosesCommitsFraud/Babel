import SwiftUI
import SwiftData

/// Wischen und Kontextmenü für Suchergebnisse: merken oder gleich komplett herunterladen.
struct RemoteStoryActions: ViewModifier {
    let remote: RemoteStory
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { download() } label: { Label("Laden", systemImage: "arrow.down.circle") }
                    .tint(theme.primary)
            }
            .swipeActions(edge: .trailing) {
                Button { add() } label: { Label("Merken", systemImage: "bookmark") }
                    .tint(.indigo)
            }
            .contextMenu {
                Button("In die Bibliothek", systemImage: "bookmark") { add() }
                if remote.source.isWebFiction || remote.source == .gutenberg {
                    Button("Herunterladen (offline)", systemImage: "arrow.down.circle") { download() }
                }
                if remote.url.scheme?.hasPrefix("http") == true {
                    ShareLink(item: remote.url)
                }
            }
    }

    private func add() {
        let story = library.story(for: remote, context: context)
        library.addToLibrary(story, context: context)
        library.updateMessage = "„\(remote.title)“ in der Bibliothek"
    }

    private func download() {
        library.updateMessage = "Lade „\(remote.title)“ …"
        Task {
            do {
                try await library.download(remote, context: context)
                library.updateMessage = "„\(remote.title)“ offline gespeichert"
            } catch {
                library.updateMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

extension View {
    func remoteStoryActions(_ remote: RemoteStory) -> some View { modifier(RemoteStoryActions(remote: remote)) }
}

/// Kurze Meldung unten (Downloads, Updates, Rate-Limit) – für alle Tabs.
struct StatusToast: View {
    @Environment(LibraryManager.self) private var library

    var body: some View {
        VStack(spacing: 8) {
            RateLimitBanner()
            if library.isCheckingUpdates {
                toast("Suche nach neuen Kapiteln …", "arrow.triangle.2.circlepath")
            } else if let message = library.updateMessage {
                toast(message, message.hasPrefix("Lade") ? "arrow.down.circle" : "checkmark.circle.fill")
                    .id(message)
                    .task(id: message) {
                        guard !message.hasPrefix("Lade") else { return }
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { if library.updateMessage == message { library.updateMessage = nil } }
                    }
            }
        }
        .animation(.snappy, value: library.updateMessage)
        .padding(.bottom, 8)
    }

    private func toast(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.medium))
            .lineLimit(2)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal)
    }
}
