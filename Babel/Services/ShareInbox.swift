import Foundation
import SwiftData

/// Eingang für „In Babel öffnen“ aus dem Teilen-Menü: Die Erweiterung legt Links und EPUB-Dateien im gemeinsamen
/// Ordner der App-Gruppe ab, die App holt sie beim nächsten Öffnen ab. Diese Datei gehört zu beiden Targets.
enum ShareInbox {
    static let groupID = "group.de.babelreader.app"

    static var folder: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let url = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Was Babel aus einem Link machen kann: Geschichten von AO3, FanFiction.net und Royal Road oder eine EPUB-Datei.
    static func isSupported(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return false }
        if host.contains("archiveofourown") { return url.path.contains("/works/") }
        if host.contains("fanfiction.net") { return url.path.contains("/s/") }
        if host.contains("royalroad.com") { return url.path.contains("/fiction/") }
        if host.hasSuffix("ncode.syosetu.com") { return url.path.count > 3 }
        return url.pathExtension.lowercased() == "epub"
    }

    static func add(link: URL) throws {
        guard let folder else { throw CocoaError(.fileWriteUnknown) }
        try Data(link.absoluteString.utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".link"), options: .atomic)
    }

    static func add(epub file: URL) throws {
        guard let folder else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(UUID().uuidString + ".epub"))
    }
}

#if !BABEL_SHARE_EXTENSION
extension ShareInbox {
    @MainActor private static var isDraining = false
    /// Schon einmal gescheitert (Seite nicht erreichbar): still weiter versuchen, nicht bei jedem Öffnen melden.
    @MainActor private static var reported: Set<String> = []

    /// Geteiltes in die Bibliothek holen. Was an der Verbindung scheitert, bleibt bis zu einer Woche liegen
    /// und wird beim nächsten Öffnen wieder versucht.
    @MainActor
    static func drain(library: LibraryManager, context: ModelContext) async {
        guard !isDraining, let folder else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { ["link", "epub"].contains($0.pathExtension) }
        guard !files.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }
        var added: [String] = []
        for file in files {
            do {
                let story: Story
                if file.pathExtension == "epub" {
                    story = try await library.importEPUB(at: file, context: context)
                } else {
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    story = try await library.importLink(text, context: context)
                }
                added.append(story.title)
                try? FileManager.default.removeItem(at: file)
            } catch {
                let age = Date().timeIntervalSince((try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                let retry: Bool
                switch error {
                case BabelError.invalidLink, BabelError.unsupported, BabelError.epub, BabelError.notFound: retry = false
                default: retry = age < 7 * 24 * 3600
                }
                if !retry { try? FileManager.default.removeItem(at: file) }
                if reported.insert(file.lastPathComponent).inserted {
                    library.updateMessage = retry
                        ? String(localized: "Geteilter Link noch nicht geladen: \(error.localizedDescription)")
                        : String(localized: "Geteiltes konnte nicht übernommen werden: \(error.localizedDescription)")
                }
            }
        }
        if added.count == 1 {
            library.updateMessage = String(localized: "„\(added[0])“ in der Bibliothek")
        } else if added.count > 1 {
            library.updateMessage = String(localized: "\(added.count) geteilte Titel in der Bibliothek")
        }
    }
}
#endif
