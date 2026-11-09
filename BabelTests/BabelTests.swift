import XCTest
@testable import Babel

/// Läuft ohne Netz. Geprüft wird, was beim Umbauen leicht kaputtgeht: ZIP/EPUB, die Parser und die Lesestelle.
/// Die HTML-Dateien unter Fixtures sind echte Seiten – ändert eine Website ihr HTML, neue Seite ablegen und Test anpassen.
final class BabelTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BabelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: ZIP und EPUB

    func testExtractsStoredAndDeflatedEntries() throws {
        let folder = try temporaryFolder()
        try ZipArchive.extract(try fixture("sample", "epub"), to: folder)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("mimetype"), encoding: .utf8), "application/epub+zip")
        let chapter = try String(contentsOf: folder.appendingPathComponent("OEBPS/Text/one.xhtml"), encoding: .utf8)
        XCTAssertTrue(chapter.hasPrefix("<html><body><p>Lorem ipsum"))
        XCTAssertTrue(chapter.hasSuffix("</p></body></html>"))
        XCTAssertEqual(chapter.components(separatedBy: "Lorem ipsum").count - 1, 200)
    }

    func testZipWriterRoundTrip() throws {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("a/b/ü.txt", Data("Grüße".utf8))
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("out.zip")
        try zip.finish().write(to: file)
        let target = folder.appendingPathComponent("out", isDirectory: true)
        try ZipArchive.extract(file, to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a/b/ü.txt"), encoding: .utf8), "Grüße")
    }

    func testRejectsBrokenArchive() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("broken.epub")
        try Data(repeating: 0x41, count: 4096).write(to: file)
        XCTAssertThrowsError(try ZipArchive.extract(file, to: folder.appendingPathComponent("x")))
    }

    func testParsesEPUB() throws {
        let folder = try temporaryFolder()
        try ZipArchive.extract(try fixture("sample", "epub"), to: folder)
        let book = try EPUBParser.parse(folder: folder)
        XCTAssertEqual(book.title, "Der Testband")
        XCTAssertEqual(book.author, "Erika Muster")
        XCTAssertEqual(book.language, "de")
        XCTAssertEqual(book.summary, "Eine kurze Probe.")
        // `linear="no"` gehört nicht zum Lesefluss; Prozentkodierung im Pfad wird aufgelöst.
        XCTAssertEqual(book.spine.map(\.path), ["OEBPS/Text/one.xhtml", "OEBPS/Text/two b.xhtml"])
        XCTAssertEqual(book.spine.map(\.title), ["Erstes Kapitel", "Zweites Kapitel"])
        XCTAssertEqual(book.coverPath, "OEBPS/Images/cover.jpg")
    }

    func testNormalizesPaths() {
        XCTAssertEqual(EPUBParser.normalize("OEBPS/Text/../Images/a.jpg"), "OEBPS/Images/a.jpg")
        XCTAssertEqual(EPUBParser.normalize("./a//b/./c"), "a/b/c")
        XCTAssertEqual(EPUBParser.normalize("../../a"), "a")
    }

    // MARK: Parser

    func testParsesGutenbergSearch() throws {
        let html = try String(contentsOf: try fixture("gutenberg-search", "html"), encoding: .utf8)
        let page = try GutenbergService.parseSearch(html, language: "de")
        XCTAssertGreaterThan(page.books.count, 10)
        let first = try XCTUnwrap(page.books.first { $0.sourceID == "5200" })
        XCTAssertEqual(first.title, "Metamorphosis")
        XCTAssertEqual(first.author, "Franz Kafka")
        XCTAssertNotNil(first.hits)
        XCTAssertEqual(first.downloadURL, GutenbergService.epubURL("5200"))
        // Jeder Treffer braucht eine ID und einen Titel – sonst hat sich das HTML geändert.
        XCTAssertTrue(page.books.allSatisfy { !$0.sourceID.isEmpty && !$0.title.isEmpty })
    }

    func testParsesFFNMetaLine() {
        var story = RemoteStory(source: .ffn, sourceID: "1", title: "T", url: URL(string: "https://www.fanfiction.net/s/1/1/")!)
        FFNService.applyMeta(
            "Rated: T - English - Romance/Hurt/Comfort - Chapters: 62 - Words: 368,834 - Reviews: 312 - Favs: 874 - Follows: 273 - Updated: Jun 14, 2009 - Published: Apr 16, 2009 - George W., OC - Complete",
            dates: [], to: &story)
        XCTAssertEqual(story.rating, "T")
        XCTAssertEqual(story.chapters, 62)
        XCTAssertEqual(story.words, 368_834)
        XCTAssertEqual(story.reviews, 312)
        XCTAssertEqual(story.favs, 874)
        XCTAssertEqual(story.follows, 273)
        XCTAssertTrue(story.isComplete)
        XCTAssertEqual(story.characters, ["George W.", "OC"])
        XCTAssertEqual(story.genres, ["Romance", "Hurt/Comfort"])
    }

    func testParsesFFNPairings() {
        var story = RemoteStory(source: .ffn, sourceID: "1", title: "T", url: URL(string: "https://www.fanfiction.net/s/1/1/")!)
        FFNService.applyMeta("Rated: M - English - Chapters: 3 - Words: 9,001 - [Harry P., Hermione G.] Ron W.", dates: [], to: &story)
        XCTAssertEqual(story.relationships.count, 1)
        XCTAssertFalse(story.isComplete)
        XCTAssertTrue(story.characters.contains("Ron W."))
    }

    func testParsesAO3ChapterFraction() {
        XCTAssertTrue(AO3Service.parseChapterFraction("3/10") == (3, 10))
        XCTAssertTrue(AO3Service.parseChapterFraction("12/?") == (12, nil))
        XCTAssertTrue(AO3Service.parseChapterFraction("1,204/1,204") == (1204, 1204))
    }

    func testShortNumbers() {
        XCTAssertEqual(873.short, "873")
        XCTAssertEqual(4517.short, "4k")
        XCTAssertEqual(10_179.short, "10k")
    }

    // MARK: Lesestelle

    func testAnchorOnlyCountsWhileItMatchesThePosition() {
        let story = Story(remote: RemoteStory(source: .ffn, sourceID: "1", title: "T", url: URL(string: "https://www.fanfiction.net/s/1/1/")!))
        XCTAssertNil(story.currentAnchor)
        story.currentChapter = 4
        story.setPosition(progress: 0.4512, anchor: 12.35)
        XCTAssertEqual(story.currentAnchor, 12.35)
        // Eine ältere App-Version kennt den Anker nicht und setzt nur den Bruchteil: Der Anker gilt dann nicht mehr.
        story.chapterProgress = 0.6
        XCTAssertNil(story.currentAnchor)
        story.setPosition(progress: 0.6, anchor: 20)
        story.currentChapter = 5
        XCTAssertNil(story.currentAnchor)
        story.setPosition(progress: 0, anchor: nil)
        XCTAssertNil(story.readingAnchor)
    }
}
