import BackgroundTasks
import SwiftData
import SwiftUI
import UserNotifications

/// Mitteilungen bei neuen Kapiteln: iOS weckt Babel ab und zu im Hintergrund (`BGAppRefreshTask`),
/// dann werden angefangene Geschichten der Bibliothek geprüft und neue Kapitel gemeldet.
/// Wann genau, entscheidet iOS – typischerweise einige Male am Tag, öfter bei häufiger Nutzung.
@MainActor
@Observable
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()
    static let taskID = "de.babelreader.app.refresh"
    static let enabledKey = "notify.newChapters"
    static let lastRunKey = "notify.lastRun"

    /// Tippen auf eine Mitteilung: diese Geschichte im Reader öffnen (RootView reagiert darauf).
    var pendingStoryKey: String?
    private(set) var permission: UNAuthorizationStatus = .notDetermined

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Hintergrundzeit ist knapp (~30 s). Danach aufhören und beim nächsten Mal mit den übrigen weitermachen.
    private static let budget: TimeInterval = 22

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Erlaubnis & Planung

    func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Fragt nach der Erlaubnis (nur beim ersten Mal erscheint der iOS-Dialog). `true` = Mitteilungen erlaubt.
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshPermission()
        return granted || permission == .authorized || permission == .provisional
    }

    /// Nächste Hintergrundprüfung anmelden (frühestens in einer Stunde) – oder abmelden, wenn ausgeschaltet.
    static func schedule() {
        guard isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(3600)
        // Im Simulator nicht verfügbar (Fehler „unavailable“) – auf dem Gerät klappt es.
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Prüfen

    /// Läuft im Hintergrund: prüft die am längsten nicht geprüften Geschichten zuerst und meldet neue Kapitel.
    func runBackgroundCheck(container: ModelContainer) async {
        Self.schedule()
        guard Self.isEnabled else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Story>(predicate: #Predicate { $0.inLibrary && !$0.isComplete && $0.lastOpenedAt != nil })
        let candidates = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.source.isWebFiction }
            // AO3 zuerst (schnell per URLSession), FFN braucht den WebView und ist langsamer.
            .sorted { a, b in
                if (a.source == .ao3) != (b.source == .ao3) { return a.source == .ao3 }
                return (a.lastCheckedAt ?? .distantPast) < (b.lastCheckedAt ?? .distantPast)
            }
        let started = Date()
        for story in candidates {
            guard !Task.isCancelled, Date().timeIntervalSince(started) < Self.budget else { break }
            guard let added = try? await LibraryManager.shared.checkForUpdates(story), added > 0 else { continue }
            await notify(story, added: added)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
    }

    private func notify(_ story: Story, added: Int) async {
        let content = UNMutableNotificationContent()
        content.title = story.title
        let latest = story.title(ofChapter: story.knownChapterCount - 1)
        content.body = added == 1
            ? String(localized: "Neues Kapitel: \(latest)")
            : String(localized: "\(added) neue Kapitel – zuletzt: \(latest)")
        if !story.author.isEmpty { content.subtitle = story.author }
        content.sound = .default
        content.threadIdentifier = story.key
        content.userInfo = ["storyKey": story.key]
        let request = UNNotificationRequest(identifier: "\(story.key)-\(story.knownChapterCount)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["storyKey"] as? String
        await MainActor.run { self.pendingStoryKey = key }
    }
}
