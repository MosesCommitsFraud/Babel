import Foundation
import SwiftData
import Observation

/// Verbindet Quellen, Dateien und SwiftData: Kapitel laden, offline speichern, Updates prüfen, importieren.
@MainActor
@Observable
final class LibraryManager {
    static let shared = LibraryManager()

    /// Download-Fortschritt pro Story-Key (0…1)
    var downloads: [String: Double] = [:]
    var isCheckingUpdates = false
    var updateMessage: String?

    private init() {}

    // MARK: - Story-Objekte

    /// Sucht die Story zu einem Suchergebnis oder legt sie an (zunächst nicht in der Bibliothek).
    func story(for remote: RemoteStory, context: ModelContext) -> Story {
        let key = remote.key
        let descriptor = FetchDescriptor<Story>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.apply(remote: remote)
            return existing
        }
        let story = Story(remote: remote)
        context.insert(story)
        try? context.save()
        return story
    }

    func addToLibrary(_ story: Story, context: ModelContext) {
        story.inLibrary = true
        if story.addedAt == nil { story.addedAt = .now }
        if story.status == .none { story.status = story.hasStarted ? .reading : .planned }
        try? context.save()
    }

    func removeFromLibrary(_ story: Story, context: ModelContext) {
        story.inLibrary = false
        story.shelves = []
        try? context.save()
    }

    func delete(_ story: Story, context: ModelContext) {
        ContentStore.deleteContent(of: story)
        context.delete(story)
        try? context.save()
    }

    func deleteOfflineContent(_ story: Story, context: ModelContext) {
        guard story.source.isWebFiction else { return }
        ContentStore.deleteContent(of: story)
        story.downloadedCount = 0
        try? context.save()
    }

    /// Löscht den Verlauf: alles, was angesehen, aber nicht in die Bibliothek gelegt wurde.
    func clearHistory(context: ModelContext) {
        let descriptor = FetchDescriptor<Story>(predicate: #Predicate { !$0.inLibrary })
        for story in (try? context.fetch(descriptor)) ?? [] {
            ContentStore.deleteContent(of: story)
            context.delete(story)
        }
        try? context.save()
    }

    // MARK: - Kapitel

    /// Gibt die Datei-URL eines Kapitels zurück und lädt es bei Bedarf herunter.
    func ensureChapter(_ story: Story, index: Int) async throws -> URL {
        switch story.source {
        case .epub, .gutenberg:
            if story.spinePaths.isEmpty { try await prepareBook(story) }
            guard index < story.spinePaths.count else { throw BabelError.notFound }
            return ContentStore.bookFolder(for: story).appendingPathComponent(story.spinePaths[index])

        case .ao3:
            let url = ContentStore.chapterURL(story, index)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            try await downloadAO3(story)
            guard FileManager.default.fileExists(atPath: url.path) else { throw BabelError.notFound }
            return url

        case .ffn:
            let url = ContentStore.chapterURL(story, index)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            try await downloadFFNChapter(story, index: index)
            return url
        }
    }

    /// AO3: ein einziger Abruf liefert das ganze Werk.
    private func downloadAO3(_ story: Story) async throws {
        let result = try await AO3Service.fetchWork(id: story.sourceID)
        for (i, chapter) in result.chapters.enumerated() {
            try ContentStore.writeChapter(chapter, story: story, index: i)
        }
        story.apply(remote: result.meta)
        story.chapterTitles = result.chapters.map(\.title)
        story.chapterCount = result.chapters.count
        story.downloadedCount = result.chapters.count
        try? story.modelContext?.save()
    }

    private func downloadFFNChapter(_ story: Story, index: Int) async throws {
        let result = try await FFNService.chapter(storyID: story.sourceID, number: index + 1)
        try ContentStore.writeChapter(result.content, story: story, index: index)
        story.apply(remote: result.meta)
        if !result.titles.isEmpty {
            story.chapterTitles = result.titles
            story.chapterCount = result.titles.count
        } else if story.chapterTitles.isEmpty {
            story.chapterTitles = [result.content.title]
        }
        story.downloadedCount = ContentStore.countDownloaded(story)
        try? story.modelContext?.save()
    }

    /// Ganze Geschichte offline speichern.
    func downloadAll(_ story: Story) async throws {
        let key = story.key
        downloads[key] = 0
        defer { downloads[key] = nil }
        switch story.source {
        case .ao3:
            if story.downloadedCount == 0 || ContentStore.countDownloaded(story) < story.knownChapterCount {
                try await downloadAO3(story)
            }
        case .ffn:
            var i = 0
            while i < max(story.chapterCount, 1) {
                if !ContentStore.hasChapter(story, i) { try await downloadFFNChapter(story, index: i) }
                i += 1
                downloads[key] = Double(i) / Double(max(story.chapterCount, 1))
            }
        case .epub, .gutenberg:
            if story.spinePaths.isEmpty { try await prepareBook(story) }
        }
    }

    /// Suchergebnis direkt in die Bibliothek legen und komplett offline speichern.
    @discardableResult
    func download(_ remote: RemoteStory, context: ModelContext) async throws -> Story {
        let story = story(for: remote, context: context)
        addToLibrary(story, context: context)
        try await downloadAll(story)
        return story
    }

    /// Ganze Geschichte laden und als EPUB-Datei (zum Teilen / Sichern) bauen.
    func exportEPUB(_ story: Story) async throws -> URL {
        switch story.source {
        case .ao3, .ffn:
            try await downloadAll(story)
            return try EPUBBuilder.build(story)
        case .gutenberg, .epub:
            throw BabelError.unsupported("Bücher liegen schon als EPUB vor")
        }
    }

    /// Viele Geschichten auf einmal übernehmen (z. B. AO3-Lesezeichen oder FFN-Favoriten).
    func importAll(_ remotes: [RemoteStory], context: ModelContext, configure: (Story) -> Void) -> Int {
        var added = 0
        for remote in remotes {
            let story = story(for: remote, context: context)
            if !story.inLibrary { added += 1 }
            addToLibrary(story, context: context)
            configure(story)
        }
        try? context.save()
        return added
    }

    /// Aus Konto-Listen übernommene Geschichten kennen oft nur Titel und Autor:in.
    /// Dann einmal die Werkseite holen (AO3) bzw. Kapitel 1 (FFN, landet gleich im Offline-Speicher).
    func refreshMetadataIfSparse(_ story: Story) async {
        guard story.source.isWebFiction, story.lastCheckedAt == nil else { return }
        let sparse = story.summary.isEmpty || (story.tags.isEmpty && story.genres.isEmpty && story.characters.isEmpty) || story.rating.isEmpty
        guard sparse else { return }
        do {
            switch story.source {
            case .ao3:
                story.apply(remote: try await AO3Service.fetchWorkMeta(id: story.sourceID))
            case .ffn:
                _ = try await ensureChapter(story, index: 0)
            default: break
            }
            story.lastCheckedAt = .now
            try? story.modelContext?.save()
        } catch {}
    }

    /// Gutenberg-Suchergebnisse haben kaum Metadaten – die Buchseite liefert Zusammenfassung und Themen.
    func enrichGutenberg(_ story: Story) async {
        guard story.source == .gutenberg, story.tags.isEmpty else { return }
        guard let details = try? await GutenbergService.details(id: story.sourceID) else { return }
        story.apply(remote: details)
        try? story.modelContext?.save()
    }

    // MARK: - Updates

    /// Prüft auf neue Kapitel. Gibt die Anzahl neuer Kapitel zurück.
    @discardableResult
    func checkForUpdates(_ story: Story) async throws -> Int {
        let before = story.knownChapterCount
        switch story.source {
        case .ao3:
            let meta = try await AO3Service.fetchWorkMeta(id: story.sourceID)
            story.apply(remote: meta)
            if meta.chapters > before || story.downloadedCount > 0 && meta.chapters > story.downloadedCount {
                try await downloadAO3(story)
            }
        case .ffn:
            let last = max(story.knownChapterCount, 1)
            let result = try await FFNService.chapter(storyID: story.sourceID, number: last)
            try ContentStore.writeChapter(result.content, story: story, index: last - 1)
            story.apply(remote: result.meta)
            if !result.titles.isEmpty {
                story.chapterTitles = result.titles
                story.chapterCount = result.titles.count
            }
        case .epub, .gutenberg:
            return 0
        }
        let diff = max(0, story.knownChapterCount - before)
        // Nur bei angefangenen Geschichten zählt das als „neu“ – sonst wären es beim ersten Abgleich
        // importierter Favoriten einfach alle Kapitel.
        if diff > 0, story.hasStarted { story.newChapters += diff }
        story.lastCheckedAt = .now
        try? story.modelContext?.save()
        return diff
    }

    func checkAllUpdates(context: ModelContext) async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let descriptor = FetchDescriptor<Story>(predicate: #Predicate { $0.inLibrary && !$0.isComplete && $0.lastOpenedAt != nil })
        let candidates = ((try? context.fetch(descriptor)) ?? []).filter { $0.source.isWebFiction }
        var total = 0
        var failed = 0
        for story in candidates {
            do { total += try await checkForUpdates(story) } catch { failed += 1 }
        }
        if total > 0 {
            updateMessage = total == 1 ? "1 neues Kapitel" : "\(total) neue Kapitel"
        } else if !candidates.isEmpty {
            updateMessage = failed > 0 ? "Keine neuen Kapitel (\(failed) nicht erreichbar)" : "Alles aktuell"
        }
    }

    // MARK: - Bücher (EPUB / Gutenberg)

    /// Lädt bei Gutenberg-Büchern das EPUB herunter und entpackt es.
    func prepareBook(_ story: Story) async throws {
        guard story.spinePaths.isEmpty else { return }
        guard story.source == .gutenberg, let url = story.downloadURLString.flatMap(URL.init(string:)) else {
            throw BabelError.epub("Buchdatei fehlt")
        }
        let key = story.key
        downloads[key] = 0.1
        defer { downloads[key] = nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try await HTTPClient.shared.download(url, to: tmp)
        downloads[key] = 0.7
        try installEPUB(at: tmp, into: story)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func installEPUB(at file: URL, into story: Story) throws {
        let bookDir = ContentStore.bookFolder(for: story)
        try? FileManager.default.removeItem(at: bookDir)
        try ZipArchive.extract(file, to: bookDir)
        let book = try EPUBParser.parse(folder: bookDir)
        if let t = book.title, !t.isEmpty { story.title = t }
        if let a = book.author, !a.isEmpty, story.author.isEmpty { story.author = a }
        if let s = book.summary, story.summary.isEmpty { story.summary = s }
        if let l = book.language, story.language.isEmpty { story.language = l }
        story.spinePaths = book.spine.map(\.path)
        story.chapterTitles = book.spine.map(\.title)
        story.chapterCount = book.spine.count
        story.coverPath = book.coverPath
        story.isComplete = true
        story.downloadedCount = book.spine.count
        try? story.modelContext?.save()
    }

    /// Eigene EPUB-Datei importieren (z. B. aus der Dateien-App).
    func importEPUB(at url: URL, context: ModelContext) throws -> Story {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.copyItem(at: url, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var remote = RemoteStory(source: .epub, sourceID: UUID().uuidString,
                                 title: url.deletingPathExtension().lastPathComponent, url: url)
        remote.isComplete = true
        let story = Story(remote: remote)
        context.insert(story)
        do {
            try installEPUB(at: tmp, into: story)
        } catch {
            ContentStore.deleteContent(of: story)
            context.delete(story)
            throw error
        }
        addToLibrary(story, context: context)
        return story
    }

    // MARK: - Links

    /// AO3-, FanFiction.net- oder direkte EPUB-Links in die Bibliothek holen.
    func importLink(_ text: String, context: ModelContext) async throws -> Story {
        guard let url = URL(string: text.trimmed), let host = url.host?.lowercased() else { throw BabelError.invalidLink }

        if host.contains("archiveofourown"), let id = url.path.firstMatch(#"/works/(\d+)"#)?[1] {
            let meta = try await AO3Service.fetchWorkMeta(id: id)
            let story = self.story(for: meta, context: context)
            addToLibrary(story, context: context)
            return story
        }
        if host.contains("fanfiction.net"), let id = url.path.firstMatch(#"/s/(\d+)"#)?[1] {
            let result = try await FFNService.chapter(storyID: id, number: 1)
            let story = self.story(for: result.meta, context: context)
            try ContentStore.writeChapter(result.content, story: story, index: 0)
            if !result.titles.isEmpty { story.chapterTitles = result.titles; story.chapterCount = result.titles.count }
            story.downloadedCount = ContentStore.countDownloaded(story)
            addToLibrary(story, context: context)
            return story
        }
        if url.pathExtension.lowercased() == "epub" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
            try await HTTPClient.shared.download(url, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return try importEPUB(at: tmp, context: context)
        }
        throw BabelError.unsupported(host)
    }
}
