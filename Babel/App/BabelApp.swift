import SwiftUI
import SwiftData

@main
struct BabelApp: App {
    @State private var reader = ReaderPresenter()
    @State private var library = LibraryManager.shared

    private let container: ModelContainer = {
        do {
            return try ModelContainer(for: Story.self, Shelf.self)
        } catch {
            fatalError("Bibliothek konnte nicht geöffnet werden: \(error)")
        }
    }()

    init() {
        // Standard: alle Ratings zeigen (FFN selbst blendet M ohne Filter aus).
        UserDefaults.standard.register(defaults: [FFNService.allRatingsKey: true])
    }

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
