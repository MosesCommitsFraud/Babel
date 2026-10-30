import SwiftUI
import SwiftData

@main
struct BabelApp: App {
    @State private var reader = ReaderPresenter()
    @State private var library = LibraryManager.shared

    init() {
        ReaderDefaults.migrate()
    }

    private let container: ModelContainer = {
        do {
            return try ModelContainer(for: Story.self, Shelf.self)
        } catch {
            fatalError("Bibliothek konnte nicht geöffnet werden: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .themeRoot()
                .environment(reader)
                .environment(library)
                .task { await CookieSync.syncFromWebKit() }
        }
        .modelContainer(container)
    }
}

/// Öffnet den Reader als Vollbild – von überall in der App.
@MainActor
@Observable
final class ReaderPresenter {
    var story: Story?
    func open(_ story: Story) { self.story = story }
}
