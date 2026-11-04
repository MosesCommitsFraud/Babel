import SwiftUI
import SwiftData

@main
struct BabelApp: App {
    @State private var reader = ReaderPresenter()
    @State private var library = LibraryManager.shared
    @State private var notifier = UpdateNotifier.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ReaderDefaults.migrate()
        SettingsSync.shared.start()
    }

    private let container = LibraryStore.open()

    var body: some Scene {
        WindowGroup {
            RootView()
                .themeRoot()
                .environment(reader)
                .environment(library)
                .environment(notifier)
                .task { await CookieSync.syncFromWebKit() }
                .task { CloudSync.shared.start(container: container) }
        }
        .modelContainer(container)
        // Beim Verlassen der App die nächste Hintergrundprüfung anmelden.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { UpdateNotifier.schedule() }
            if phase == .active { CloudSync.shared.scheduleCleanup() }
        }
        .backgroundTask(.appRefresh(UpdateNotifier.taskID)) { [container] in
            await UpdateNotifier.shared.runBackgroundCheck(container: container)
        }
    }
}

/// Öffnet den Reader als Vollbild – von überall in der App.
@MainActor
@Observable
final class ReaderPresenter {
    var story: Story? {
        didSet { hold = story.map { StoryHold(key: $0.key) } }
    }
    @ObservationIgnored private var hold: StoryHold?
    func open(_ story: Story) { self.story = story }
}
