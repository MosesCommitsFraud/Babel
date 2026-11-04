import SwiftUI
import SwiftData
import CoreData
import CloudKit

/// Den Abgleich selbst erledigt SwiftData. Hier liegt, was darum herum nötig ist:
/// Status für die Einstellungen und das Zusammenführen doppelter Zeilen. CloudKit kennt kein `.unique`:
/// Öffnen zwei Geräte dieselbe Geschichte, bevor sie sich gesehen haben, gibt es danach zwei Zeilen mit demselben `key`.
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Account { case unknown, available, noAccount, restricted, unavailable }

    private(set) var account: Account = .unknown
    private(set) var isSyncing = false
    private(set) var lastSync: Date? = {
        let time = UserDefaults.standard.double(forKey: lastSyncKey)
        return time > 0 ? Date(timeIntervalSince1970: time) : nil
    }()
    private(set) var errorText: String?
    /// Die Bibliothek wurde mit iCloud geöffnet (sonst nur lokal, siehe `LibraryStore`).
    private(set) var isEnabled = false

    private static let lastSyncKey = "cloud.lastSync"
    private var container: ModelContainer?
    private var observers: [NSObjectProtocol] = []
    private var cleanupTask: Task<Void, Never>?
    /// Eine Duplikat-Gruppe wurde übersprungen, weil sie gerade offen ist.
    private var cleanupPending = false
    private var pruneAfterCleanup = false

    private init() {}

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        isEnabled = LibraryStore.isCloudEnabled
        scheduleCleanup()
        guard isEnabled else { return }
        Task { await refreshAccount() }
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            let finished = event.endDate
            let type = event.type
            let succeeded = event.succeeded
            let error = event.error
            MainActor.assumeIsolated { self?.handle(type: type, finished: finished, succeeded: succeeded, error: error) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshAccount() }
        })
    }

    private func refreshAccount() async {
        let status = try? await CKContainer(identifier: LibraryStore.containerID).accountStatus()
        switch status {
        case .available: account = .available
        case .noAccount: account = .noAccount
        case .restricted: account = .restricted
        case .temporarilyUnavailable, .couldNotDetermine, nil: account = .unavailable
        @unknown default: account = .unavailable
        }
    }

    private func handle(type: NSPersistentCloudKitContainer.EventType, finished: Date?, succeeded: Bool, error: Error?) {
        guard let finished else {
            isSyncing = true
            return
        }
        isSyncing = false
        guard succeeded else {
            errorText = error.map(Self.describe)
            return
        }
        errorText = nil
        guard type != .setup else { return }
        lastSync = finished
        UserDefaults.standard.set(finished.timeIntervalSince1970, forKey: Self.lastSyncKey)
        if type == .import {
            pruneAfterCleanup = true
            scheduleCleanup()
        }
    }

    private static func describe(_ error: Error) -> String {
        switch (error as? CKError)?.code {
        case .quotaExceeded: String(localized: "Dein iCloud-Speicher ist voll.")
        case .networkUnavailable, .networkFailure: String(localized: "Keine Verbindung zu iCloud.")
        case .notAuthenticated: String(localized: "Nicht bei iCloud angemeldet.")
        default: error.localizedDescription
        }
    }

    // MARK: - Doppelte Zeilen

    /// Kurz gesammelt: Ein Abgleich kommt oft in mehreren Schüben.
    func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.cleanUp()
        }
    }

    fileprivate func holdReleased() {
        if cleanupPending { scheduleCleanup() }
    }

    private func cleanUp() {
        guard let context = container?.mainContext else { return }
        cleanupPending = false
        mergeShelves(context)
        mergeStories(context)
        try? context.save()
        if pruneAfterCleanup {
            pruneAfterCleanup = false
            pruneFolders(context)
        }
    }

    private func mergeStories(_ context: ModelContext) {
        var descriptor = FetchDescriptor<Story>()
        descriptor.propertiesToFetch = [\.key, \.syncID]
        guard let stories = try? context.fetch(descriptor) else { return }
        let held = StoryHold.heldKeys.union([ReadAloudPlayer.shared.story?.key].compactMap { $0 })
        for group in Dictionary(grouping: stories, by: \.key).values where group.count > 1 {
            // Die Zeile einer offenen Ansicht darf nicht verschwinden. Später nochmal.
            if held.contains(group[0].key) {
                cleanupPending = true
                continue
            }
            // Überall dieselbe Zeile behalten, sonst löschen zwei Geräte über Kreuz beide.
            // Mit `<` vergleichen: `SortDescriptor` sortiert Strings je nach Spracheinstellung des Geräts.
            let ordered = group.sorted { $0.syncID < $1.syncID }
            guard Set(group.map(\.syncID)).count == group.count, let keep = ordered.first else { continue }
            for duplicate in ordered.dropFirst() {
                keep.absorb(duplicate)
                context.delete(duplicate)
            }
        }
    }

    private func mergeShelves(_ context: ModelContext) {
        guard let shelves = try? context.fetch(FetchDescriptor<Shelf>()) else { return }
        for group in Dictionary(grouping: shelves, by: \.name).values where group.count > 1 {
            let ordered = group.sorted { $0.syncID < $1.syncID }
            guard Set(group.map(\.syncID)).count == group.count, let keep = ordered.first else { continue }
            for duplicate in ordered.dropFirst() {
                keep.createdAt = min(keep.createdAt, duplicate.createdAt)
                for story in duplicate.stories ?? [] where !story.shelfList.contains(where: { $0.persistentModelID == keep.persistentModelID }) {
                    story.shelfList.append(keep)
                }
                context.delete(duplicate)
            }
        }
    }

    /// Nur direkt nach einem erfolgreichen Abgleich und nie bei leerer Bibliothek:
    /// Beim Abmelden von iCloud räumt iOS die Bibliothek leer – die Kapitel sollen das überstehen.
    private func pruneFolders(_ context: ModelContext) {
        var descriptor = FetchDescriptor<Story>()
        descriptor.propertiesToFetch = [\.folderName]
        guard let stories = try? context.fetch(descriptor), !stories.isEmpty else { return }
        ContentStore.pruneFolders(keeping: Set(stories.map(\.folderName)))
    }

    #if DEBUG
    /// Mit einem Gerät lässt sich kein Abgleich erzeugen – hier von Hand doppelte Zeilen anlegen, wie sie zwei Geräte hinterlassen würden.
    /// Zusammengeführt wird beim nächsten Wechsel in den Vordergrund, so lässt sich vorher eine davon öffnen.
    func insertTestDuplicates() {
        guard let context = container?.mainContext else { return }
        var descriptor = FetchDescriptor<Story>(predicate: #Predicate { $0.lastOpenedAt != nil }, sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        for story in (try? context.fetch(descriptor)) ?? [] {
            let copy = Story(remote: story.asRemote)
            copy.currentChapter = story.currentChapter + 1
            copy.chapterProgress = 0.5
            copy.lastOpenedAt = .now
            copy.isFavorite = true
            let shelf = Shelf(name: "Sync-Test")
            context.insert(copy)
            context.insert(shelf)
            copy.shelfList.append(shelf)
        }
        try? context.save()
    }
    #endif
}

/// Hält eine Geschichte fest, solange eine Ansicht sie zeigt: Ihre Zeile wird dann nicht zusammengeführt.
final class StoryHold {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private let key: String

    static var heldKeys: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(counts.keys)
    }

    init(key: String) {
        self.key = key
        Self.lock.lock()
        Self.counts[key, default: 0] += 1
        Self.lock.unlock()
    }

    deinit {
        Self.lock.lock()
        let left = (Self.counts[key] ?? 1) - 1
        Self.counts[key] = left > 0 ? left : nil
        Self.lock.unlock()
        if left <= 0 {
            Task { @MainActor in CloudSync.shared.holdReleased() }
        }
    }
}

extension Story {
    /// Übernimmt alles von einer doppelten Zeile: Die Lesestelle des zuletzt gelesenen Geräts,
    /// sonst gewinnt, was gesetzt ist. Danach kann `other` weg.
    func absorb(_ other: Story) {
        let otherIsNewer = (other.lastOpenedAt ?? .distantPast) > (lastOpenedAt ?? .distantPast)
        if otherIsNewer {
            currentChapter = other.currentChapter
            chapterProgress = other.chapterProgress
            lastOpenedAt = other.lastOpenedAt
        }
        if status == .none || (otherIsNewer && other.status != .none) { status = other.status }

        inLibrary = inLibrary || other.inLibrary
        userRemoved = (userRemoved || other.userRemoved) && !inLibrary
        isFavorite = isFavorite || other.isFavorite
        newChapters = max(newChapters, other.newChapters)
        addedAt = [addedAt, other.addedAt].compactMap { $0 }.min()
        viewedAt = [viewedAt, other.viewedAt].compactMap { $0 }.max()
        lastCheckedAt = [lastCheckedAt, other.lastCheckedAt].compactMap { $0 }.max()
        if personalNote.isEmpty {
            personalNote = other.personalNote
        } else if !other.personalNote.isEmpty, other.personalNote != personalNote {
            personalNote += "\n\n" + other.personalNote
        }

        // `apply` lässt leere Felder aus: erst die fremden Angaben übernehmen, dann die eigenen wieder darüber.
        let own = asRemote
        apply(remote: other.asRemote)
        apply(remote: own)
        if other.chapterTitles.count > chapterTitles.count { chapterTitles = other.chapterTitles }
        if spinePaths.isEmpty { spinePaths = other.spinePaths }
        if coverPath == nil { coverPath = other.coverPath }
        chapterCount = max(chapterCount, other.chapterCount)

        for shelf in other.shelfList where !shelfList.contains(where: { $0.persistentModelID == shelf.persistentModelID }) {
            shelfList.append(shelf)
        }
    }
}

/// Einstellungen → iCloud.
struct CloudSyncSection: View {
    @State private var sync = CloudSync.shared

    private var statusText: String {
        guard sync.isEnabled else { return String(localized: "Nicht verfügbar") }
        switch sync.account {
        case .unknown: return "–"
        case .noAccount: return String(localized: "Nicht angemeldet")
        case .restricted: return String(localized: "Eingeschränkt")
        case .unavailable: return String(localized: "Nicht erreichbar")
        case .available: return sync.isSyncing ? String(localized: "Wird abgeglichen …") : String(localized: "Aktiv")
        }
    }

    var body: some View {
        Section {
            LabeledContent {
                Text(statusText)
            } label: {
                Label("iCloud-Abgleich", systemImage: "icloud")
            }
            if let lastSync = sync.lastSync {
                LabeledContent("Zuletzt abgeglichen", value: lastSync.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = sync.errorText {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            #if DEBUG
            Button("Doppelte Zeilen anlegen (Debug)", systemImage: "ladybug") { sync.insertTestDuplicates() }
            #endif
        } header: {
            Text("iCloud")
        } footer: {
            Text("Bibliothek, Lesestellen, Sammlungen und Einstellungen gleichen sich über dein iCloud-Konto ab. Kapitel lädt jedes Gerät selbst, importierte EPUB-Dateien bleiben auf dem Gerät, die Anmeldung bei AO3 und FanFiction.net gilt pro Gerät.")
        }
        .themedRows()
    }
}
