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

    func testParsesRoyalRoadList() throws {
        let html = try String(contentsOf: try fixture("royalroad-list", "html"), encoding: .utf8)
        let page = try RoyalRoadService.parseList(html)
        XCTAssertEqual(page.stories.map(\.sourceID), ["21220", "36735"])
        XCTAssertTrue(page.hasNext)
        let first = page.stories[0]
        XCTAssertEqual(first.title, "Mother of Learning")
        XCTAssertEqual(first.tags, ["Time Loop", "Adventure"])
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.follows, 34_388)
        XCTAssertEqual(first.hits, 28_838_070)
        XCTAssertEqual(first.chapters, 109)
        XCTAssertEqual(first.words, 2_932 * 275)
        XCTAssertEqual(first.coverURL?.pathExtension, "jpg")
        XCTAssertNotNil(first.updated)
        XCTAssertTrue(first.summary.hasPrefix("Zorian is a teenage mage"))
        XCTAssertEqual(first.genres, ["Original"])
        XCTAssertEqual(first.categories.count, 1, "Stand als eigene Angabe")
        XCTAssertFalse(page.stories[1].isComplete)
        XCTAssertEqual(page.stories[1].categories.count, 1)
        XCTAssertNil(page.stories[1].coverURL)
    }

    func testParsesRoyalRoadFiction() throws {
        let html = try String(contentsOf: try fixture("royalroad-fiction", "html"), encoding: .utf8)
        let fiction = try RoyalRoadService.parseFiction(html, id: "21220")
        XCTAssertEqual(fiction.meta.title, "Mother of Learning")
        XCTAssertEqual(fiction.meta.author, "nobody103")
        XCTAssertEqual(fiction.meta.authorURL?.path, "/profile/100374")
        XCTAssertTrue(fiction.meta.isComplete)
        XCTAssertEqual(fiction.meta.words, 806_306)
        XCTAssertEqual(fiction.meta.warnings, ["Graphic Violence", "Profanity"])
        XCTAssertEqual(fiction.meta.genres, ["Original"])
        XCTAssertEqual(fiction.meta.categories.count, 1)
        XCTAssertEqual(fiction.meta.follows, 34_388)
        XCTAssertEqual(fiction.meta.favs, 32_960)
        XCTAssertEqual(fiction.meta.hits, 28_838_070)
        XCTAssertEqual(fiction.meta.summary.components(separatedBy: "\n\n").count, 2)
        // Kapitel kommen aus dem Skript der Seite, sortiert nach `order`.
        XCTAssertEqual(fiction.titles, ["1. Good Morning Brother", "2. Life’s Little Problems", "3. The Bitter Truth"])
        XCTAssertEqual(fiction.paths.first, "/fiction/21220/mother-of-learning/chapter/301778/1-good-morning-brother")
        XCTAssertEqual(fiction.meta.chapters, 3)
    }

    func testParsesRoyalRoadChapter() throws {
        let html = try String(contentsOf: try fixture("royalroad-chapter", "html"), encoding: .utf8)
        let chapter = try RoyalRoadService.parseChapter(html, fallbackTitle: "Kapitel 1")
        XCTAssertEqual(chapter.title, "1. Good Morning Brother")
        XCTAssertTrue(chapter.html.contains("Zorian’s eyes abruptly shot open"))
        // Per CSS ausgeblendete Einschübe gehören nicht zum Text.
        XCTAssertFalse(chapter.html.contains("hidden on the website"))
        // Die Anmerkung steht vor dem Text.
        let note = try XCTUnwrap(chapter.html.range(of: "Thanks for reading."))
        let text = try XCTUnwrap(chapter.html.range(of: "Zorian’s eyes"))
        XCTAssertLessThan(note.lowerBound, text.lowerBound)
    }

    func testParsesOPDSFeed() throws {
        let xml = try String(contentsOf: try fixture("opds-unglue", "xml"), encoding: .utf8)
        let feed = try OPDSService.parse(xml, url: URL(string: "https://unglue.it/api/opds/all/?order_by=popular")!)
        XCTAssertNotNil(feed.next)
        XCTAssertEqual(feed.books.count + feed.hiddenCount, 4)
        let book = try XCTUnwrap(feed.books.first { $0.title == "So You Want to Be a Librarian" })
        XCTAssertEqual(book.author, "Lauren Pressley")
        XCTAssertEqual(book.language, "EN")
        XCTAssertEqual(book.downloadURL?.host, "unglue.it")
        XCTAssertNotNil(book.coverURL)
        XCTAssertTrue(book.tags.contains("Education"))
        XCTAssertTrue(book.source.isOnlineBook)
        XCTAssertEqual(book.categories.first, "CC BY-SA", "Lizenz vom Download-Link")
        XCTAssertGreaterThanOrEqual(book.tags.count, 7, "alle Themen, nicht nur die ersten")
    }

    func testParsesOPDSNavigation() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Katalog</title>
        <link rel="search" type="application/atom+xml" href="/opds/search?q={searchTerms}"/>
        <entry><title>Beliebt</title><content type="text">Die meistgelesenen</content>
        <link rel="http://opds-spec.org/sort/popular" type="application/atom+xml;profile=opds-catalog" href="popular/"/></entry>
        </feed>
        """
        let feed = try OPDSService.parse(xml, url: URL(string: "https://example.org:8083/opds/")!)
        XCTAssertEqual(feed.searchTemplate, "https://example.org:8083/opds/search?q={searchTerms}")
        XCTAssertEqual(feed.featured?.absoluteString, "https://example.org:8083/opds/popular/")
        guard case .navigation(let title, let subtitle, let url)? = feed.entries.first else { return XCTFail("Kein Ordner") }
        XCTAssertEqual(title, "Beliebt")
        XCTAssertEqual(subtitle, "Die meistgelesenen")
        XCTAssertEqual(url.absoluteString, "https://example.org:8083/opds/popular/")
    }

    /// Nachgebautes AO3-HTML (AO3 war beim Schreiben in Wartung) – prüft die Logik, nicht die echte Seite.
    func testParsesAO3Series() throws {
        func blurb(_ id: Int, _ title: String, part: Int?) -> String {
            let series = part.map { "<ul class=\"series\"><li>Part <strong>\($0)</strong> of <a href=\"/series/77\">Die Reihe</a></li></ul>" } ?? ""
            return "<li class=\"work blurb group\"><div class=\"header module\"><h4 class=\"heading\"><a href=\"/works/\(id)\">\(title)</a> by <a rel=\"author\" href=\"/users/a/pseuds/a\">a</a></h4></div>\(series)<dl class=\"stats\"><dd class=\"chapters\">3/3</dd><dd class=\"words\">1,200</dd></dl></li>"
        }
        let html = """
        <div id="main"><h2 class="heading">Die Reihe</h2>
        <dl class="series meta group"><dt>Creator:</dt><dd><a rel="author" href="/users/a/pseuds/a">a</a></dd>
        <dt>Description:</dt><dd><blockquote class="userstuff"><p>Worum es geht.</p></blockquote></dd>
        <dt class="stats">Stats:</dt><dd class="stats"><dl class="stats"><dt>Words:</dt><dd>12,345</dd><dt>Works:</dt><dd>2</dd><dt>Complete:</dt><dd>Yes</dd></dl></dd></dl>
        <ul class="series work index group">\(blurb(1, "Eins", part: 1))\(blurb(2, "Zwei", part: nil))</ul></div>
        """
        let series = try AO3Service.parseSeries(html, id: "77")
        XCTAssertEqual(series.title, "Die Reihe")
        XCTAssertEqual(series.creator, "a")
        XCTAssertEqual(series.summary, "Worum es geht.")
        XCTAssertEqual(series.words, 12_345)
        XCTAssertEqual(series.workCount, 2)
        XCTAssertTrue(series.isComplete)
        XCTAssertEqual(series.works.map(\.title), ["Eins", "Zwei"])
        XCTAssertEqual(series.works.map { $0.series?.position }, [1, 2])
        // Gespeicherte Einträge ohne Serie (das Feld fehlt dann im JSON) laden weiter.
        let plain = RemoteStory(source: .ao3, sourceID: "1", title: "T", url: URL(string: "https://archiveofourown.org/works/1")!)
        let data = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("series"))
        XCTAssertNil(try JSONDecoder().decode(RemoteStory.self, from: data).series)
    }

    func testBookLanguages() throws {
        // Ohne eigene Auswahl gilt die Lesesprache aus den Einstellungen (AO3 schreibt „ptBR“).
        XCTAssertEqual(BookLanguages.codes(stored: "", reading: "de"), ["de"])
        XCTAssertEqual(BookLanguages.codes(stored: "", reading: "ptBR"), ["pt"])
        XCTAssertEqual(BookLanguages.codes(stored: "", reading: ""), [])
        XCTAssertEqual(BookLanguages.codes(stored: "de,en", reading: "fr"), ["de", "en"])
        // „Alle Sprachen“ bewusst gewählt – nicht wieder auf die Lesesprache zurückfallen.
        XCTAssertEqual(BookLanguages.codes(stored: BookLanguages.stored([]), reading: "de"), [])

        var book = RemoteStory(source: .opds, sourceID: "1", title: "T", url: URL(string: "https://example.org")!)
        XCTAssertTrue(BookLanguages.matches(book, ["de"]), "ohne Sprachangabe bleibt das Buch")
        book.language = "EN"
        XCTAssertFalse(BookLanguages.matches(book, ["de"]))
        XCTAssertTrue(BookLanguages.matches(book, ["de", "en"]))
        book.language = "English"
        XCTAssertTrue(BookLanguages.matches(book, ["en"]))
        XCTAssertTrue(BookLanguages.matches(book, []))

        // Quellen ohne Bücher in den Lesesprachen fallen weg; Kataloge ohne Sprachangabe nie.
        XCTAssertFalse(BookShelf(kind: .serial(.royalRoad)).offers(["de"]))
        XCTAssertTrue(BookShelf(kind: .serial(.royalRoad)).offers(["de", "en"]))
        XCTAssertTrue(BookShelf(kind: .library(.gutenberg)).offers(["de"]))
        XCTAssertFalse(BookShelf(kind: .library(.standardEbooks)).offers(["de"]))
        let own = OPDSCatalog(title: "Mein Server", url: URL(string: "https://example.org/opds")!)
        XCTAssertTrue(BookShelf(kind: .catalog(own)).offers(["de"]))

        // Kataloge aus älteren Versionen kennen keine Sprachen.
        let old = try JSONDecoder().decode([OPDSCatalog].self, from: Data(#"[{"title":"A","url":"https://example.org/opds","about":""}]"#.utf8))
        XCTAssertEqual(old.first?.languages, [])
    }

    func testPageBackColorFollowsTheme() {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
        // Helles Papier: Rückseite dunkler. Schwarz: etwas heller, aber weit weg von Weiß.
        XCTAssertLessThan(luminance(BookLeaf.backColor(for: .white)), 0.9)
        XCTAssertGreaterThan(luminance(BookLeaf.backColor(for: .white)), 0.7)
        XCTAssertLessThan(luminance(BookLeaf.backColor(for: .black)), 0.15)
        XCTAssertGreaterThan(luminance(BookLeaf.backColor(for: .black)), 0)
    }

    func testSyosetuOnlyForJapanese() {
        XCTAssertFalse(BookShelf(kind: .serial(.syosetu)).offers(["de", "en"]))
        XCTAssertTrue(BookShelf(kind: .serial(.syosetu)).offers(["ja"]))
        XCTAssertTrue(StorySource.syosetu.isWebFiction)
    }

    func testParsesSyosetuChapter() throws {
        let html = """
        <h1 class="p-novel__title p-novel__title--rensai">第一話</h1>
        <div class="p-novel__body">
        <div class="js-novel-text p-novel__text p-novel__text--preface"><p id="Lp1">まえがき</p></div>
        <div class="js-novel-text p-novel__text"><p id="L1">一行目</p><p id="L2"><br></p><p id="L3"><ruby>漢字<rt>かんじ</rt></ruby>の行</p></div>
        </div>
        """
        let chapter = try SyosetuService.parseChapter(html, fallbackTitle: "Kapitel 1")
        XCTAssertEqual(chapter.title, "第一話")
        XCTAssertTrue(chapter.html.contains("lang=\"ja\""))
        XCTAssertTrue(chapter.html.contains("babel-gap"), "Leerzeile wird zum Abstand")
        XCTAssertTrue(chapter.html.contains("<ruby>"), "Lesehilfen bleiben")
        XCTAssertTrue(chapter.html.contains("babel-notes"), "Vorwort als Anmerkung")
        XCTAssertEqual(try SyosetuService.parseContents("<div class=\"p-eplist__sublist\"><a href=\"/n1/1/\" class=\"p-eplist__subtitle\"> １ 題 </a></div>"), ["１ 題"])
    }

    func testMergesScannedPages() throws {
        let folder = try temporaryFolder()
        var paths: [String] = []
        for i in 0..<60 {
            let name = "page_\(i).html"
            // Jede dritte Seite ist leer – sie fällt weg.
            let body = i % 3 == 2 ? "<p> </p>" : "<p>Seite \(i) Text</p>"
            try Data("<html><head><title>Page \(i)</title><link href=\"style.css\" rel=\"stylesheet\"/></head><body>\(body)</body></html>".utf8)
                .write(to: folder.appendingPathComponent(name))
            paths.append(name)
        }
        let merged = try XCTUnwrap(EPUBParser.mergePages(paths, folder: folder, tocCount: 0))
        XCTAssertLessThan(merged.count, 10)
        let first = try String(contentsOf: folder.appendingPathComponent(merged[0].path), encoding: .utf8)
        XCTAssertTrue(first.contains("style.css"), "Stylesheet der Seiten bleibt")
        XCTAssertTrue(first.contains("Seite 0 Text") && first.contains("Seite 1 Text"))
        XCTAssertFalse(first.contains("babel-page-3\""), "leere Seite fehlt")
        // Bücher mit echten Kapiteln bleiben unangetastet.
        XCTAssertNil(EPUBParser.mergePages(Array(paths.prefix(20)), folder: folder, tocCount: 0))
        XCTAssertNil(EPUBParser.mergePages(paths, folder: folder, tocCount: 30))
    }

    func testDocumentTitle() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("a.html")
        try Data("<html><head><title>Website</title></head><body><h2 class=\"x\"><a id=\"a\"></a>XI<br/>LE VIEUX  CRIME</h2><p>…</p></body></html>".utf8).write(to: file)
        XCTAssertEqual(EPUBParser.documentTitle(file), "XI LE VIEUX CRIME")
        try Data("<html><head><title>Nur Titel</title></head><body><p>…</p></body></html>".utf8).write(to: file)
        XCTAssertEqual(EPUBParser.documentTitle(file), "Nur Titel")
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
