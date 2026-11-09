import Foundation
import Observation

/// Was von einer Geschichte auf diesem Gerät liegt. Pro Geschichte beobachtbar:
/// Ein geladenes Kapitel zeichnet nur die Ansichten dieser Geschichte neu.
@Observable
final class OfflineState {
    var chapterFiles = 0
    var hasBook = false
}

/// Kapitel und Bücher liegen als Dateien unter Application Support/Babel/Stories/<Ordner>/.
/// Sie werden nicht per iCloud abgeglichen: Jedes Gerät lädt sie selbst nach, was es zum Lesen braucht.
enum ContentStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Babel/Stories", isDirectory: true)
        // Aus der Zeit, als die App noch „Folio“ hieß.
        let legacy = base.appendingPathComponent("Folio", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: base.appendingPathComponent("Babel").path) {
            try? FileManager.default.moveItem(at: legacy, to: base.appendingPathComponent("Babel", isDirectory: true))
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let lock = NSLock()
    private static var offlineStates: [String: OfflineState] = [:]

    /// Einmal von der Platte gelesen, danach aus dem Speicher – geht auch in Filtern über die ganze Bibliothek.
    static func offlineState(folderName: String) -> OfflineState {
        lock.lock()
        defer { lock.unlock() }
        if let state = offlineStates[folderName] { return state }
        let state = OfflineState()
        read(folderName, into: state)
        offlineStates[folderName] = state
        return state
    }

    private static func read(_ folderName: String, into state: OfflineState) {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let chapterFiles = files.filter { $0.hasPrefix("ch_") }.count
        let hasBook = files.contains("book")
        if state.chapterFiles != chapterFiles { state.chapterFiles = chapterFiles }
        if state.hasBook != hasBook { state.hasBook = hasBook }
    }

    /// Nach jeder Änderung an den Dateien einer Geschichte aufrufen.
    static func refreshOfflineState(folderName: String) {
        read(folderName, into: offlineState(folderName: folderName))
    }

    /// Das Buch liegt auf diesem Gerät. `spinePaths` allein sagt das nicht: Es kommt per iCloud auch von anderen Geräten.
    static func isBookInstalled(_ story: Story) -> Bool {
        !story.spinePaths.isEmpty && offlineState(folderName: story.folderName).hasBook
    }

    /// Ordner, die in diesem Lauf schon angelegt wurden – `folder(for:)` läuft pro Listenzeile.
    private static var createdFolders: Set<String> = []

    static func folder(for story: Story) -> URL { folder(named: story.folderName) }

    static func folder(named folderName: String) -> URL {
        let url = root.appendingPathComponent(folderName, isDirectory: true)
        lock.lock()
        let isNew = createdFolders.insert(folderName).inserted
        lock.unlock()
        if isNew { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func bookFolder(for story: Story) -> URL {
        folder(for: story).appendingPathComponent("book", isDirectory: true)
    }

    static func chapterURL(_ story: Story, _ index: Int) -> URL {
        folder(for: story).appendingPathComponent(chapterFileName(index))
    }

    static func hasChapter(_ story: Story, _ index: Int) -> Bool {
        if !story.source.isWebFiction {
            return isBookInstalled(story) && index < story.spinePaths.count
        }
        return FileManager.default.fileExists(atPath: chapterURL(story, index).path)
    }

    static func countDownloaded(_ story: Story) -> Int {
        if !story.source.isWebFiction { return isBookInstalled(story) ? story.spinePaths.count : 0 }
        return offlineState(folderName: story.folderName).chapterFiles
    }

    static func writeChapter(_ chapter: ChapterContent, story: Story, index: Int) throws {
        try write(chapter, to: chapterURL(story, index))
        refreshOfflineState(folderName: story.folderName)
    }

    /// Ein ganzes Werk auf einmal (AO3 liefert alle Kapitel in einem Abruf): im Hintergrund schreiben,
    /// den Zustand danach einmal auffrischen – nicht pro Kapitel den Ordner neu lesen.
    @MainActor
    static func writeChapters(_ chapters: [ChapterContent], story: Story) async throws {
        let folderName = story.folderName
        let folder = folder(named: folderName)
        defer { refreshOfflineState(folderName: folderName) }
        try await Task.detached(priority: .userInitiated) {
            for (i, chapter) in chapters.enumerated() {
                try write(chapter, to: folder.appendingPathComponent(chapterFileName(i)))
            }
        }.value
    }

    private static func chapterFileName(_ index: Int) -> String { String(format: "ch_%04d.html", index) }

    private static func write(_ chapter: ChapterContent, to url: URL) throws {
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(chapter.title.htmlEscaped)</title></head>
        <body><h1 class="babel-title">\(chapter.title.htmlEscaped)</h1>
        \(chapter.html)
        </body></html>
        """
        try Data(html.utf8).write(to: url, options: .atomic)
    }

    static func deleteContent(of story: Story) {
        deleteContent(folderName: story.folderName)
    }

    private static func deleteContent(folderName: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folderName, isDirectory: true))
        lock.lock()
        createdFolders.remove(folderName)
        lock.unlock()
        refreshOfflineState(folderName: folderName)
    }

    /// Räumt Kapitel von Geschichten weg, die auf einem anderen Gerät gelöscht wurden.
    /// Eigene EPUBs bleiben: Ihre Dateien lassen sich nicht neu laden.
    static func pruneFolders(keeping folderNames: Set<String>) {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let ownBooks = StorySource.epub.rawValue + "_"
        for folder in folders where !folderNames.contains(folder) && !folder.hasPrefix(ownBooks) && !folder.hasPrefix(".") {
            deleteContent(folderName: folder)
        }
    }

    static func coverFileURL(_ story: Story) -> URL? {
        guard let p = story.coverPath, offlineState(folderName: story.folderName).hasBook else { return nil }
        return bookFolder(for: story).appendingPathComponent(p)
    }

    static func totalSize() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
