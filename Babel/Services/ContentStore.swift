import Foundation

/// Kapitel und Bücher liegen als Dateien unter Application Support/Babel/Stories/<Ordner>/.
enum ContentStore {
    static var root: URL {
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
    }

    static func folder(for story: Story) -> URL {
        let url = root.appendingPathComponent(story.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func bookFolder(for story: Story) -> URL {
        folder(for: story).appendingPathComponent("book", isDirectory: true)
    }

    static func chapterURL(_ story: Story, _ index: Int) -> URL {
        folder(for: story).appendingPathComponent(String(format: "ch_%04d.html", index))
    }

    static func hasChapter(_ story: Story, _ index: Int) -> Bool {
        if !story.source.isWebFiction {
            return index < story.spinePaths.count
        }
        return FileManager.default.fileExists(atPath: chapterURL(story, index).path)
    }

    static func countDownloaded(_ story: Story) -> Int {
        if !story.source.isWebFiction { return story.spinePaths.count }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder(for: story).path)) ?? []
        return files.filter { $0.hasPrefix("ch_") }.count
    }

    static func writeChapter(_ chapter: ChapterContent, story: Story, index: Int) throws {
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(chapter.title.htmlEscaped)</title></head>
        <body><h1 class="babel-title">\(chapter.title.htmlEscaped)</h1>
        \(chapter.html)
        </body></html>
        """
        try Data(html.utf8).write(to: chapterURL(story, index), options: .atomic)
    }

    static func deleteContent(of story: Story) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(story.folderName, isDirectory: true))
    }

    static func coverFileURL(_ story: Story) -> URL? {
        guard let p = story.coverPath else { return nil }
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
