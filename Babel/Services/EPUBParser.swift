import Foundation
import NaturalLanguage
import SwiftSoup

struct EPUBBook {
    struct Item { let path: String; let title: String }
    var title: String?
    var author: String?
    var summary: String?
    var language: String?
    var spine: [Item]
    var coverPath: String?
}

/// Liest ein entpacktes EPUB (container.xml → OPF → Spine + Inhaltsverzeichnis).
enum EPUBParser {
    static func parse(folder: URL) throws -> EPUBBook {
        let containerURL = folder.appendingPathComponent("META-INF/container.xml")
        guard let containerXML = try? String(contentsOf: containerURL, encoding: .utf8) else {
            throw BabelError.epub(String(localized: "META-INF/container.xml fehlt"))
        }
        let container = try SwiftSoup.parse(containerXML, "", Parser.xmlParser())
        guard let opfPath = try container.select("rootfile").first()?.attr("full-path"), !opfPath.isEmpty else {
            throw BabelError.epub(String(localized: "Kein OPF gefunden"))
        }
        let opfURL = folder.appendingPathComponent(opfPath)
        guard let opfXML = try? String(contentsOf: opfURL, encoding: .utf8) else { throw BabelError.epub(String(localized: "OPF nicht lesbar")) }
        let opf = try SwiftSoup.parse(opfXML, "", Parser.xmlParser())
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        func rel(_ href: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            let joined = opfDir.isEmpty ? decoded : "\(opfDir)/\(decoded)"
            return normalize(joined)
        }

        // Metadaten (Namespaces wie dc:title werden über den Tag-Namen erkannt)
        func meta(_ name: String) throws -> String? {
            for el in try opf.getAllElements().array() {
                let tag = el.tagName().lowercased()
                if tag == "dc:\(name)" || tag == name, el.parent()?.tagName().lowercased().hasSuffix("metadata") == true {
                    let t = try el.text().trimmed
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }

        // Manifest
        struct ManifestItem { let id: String; let href: String; let type: String; let props: String }
        var manifest: [String: ManifestItem] = [:]
        for item in try opf.select("item").array() {
            let id = try item.attr("id")
            manifest[id] = ManifestItem(id: id, href: try item.attr("href"), type: try item.attr("media-type"), props: try item.attr("properties"))
        }

        // Inhaltsverzeichnis: EPUB3 nav oder EPUB2 NCX
        var tocTitles: [String: String] = [:]
        if let nav = manifest.values.first(where: { $0.props.contains("nav") }) {
            let navPath = rel(nav.href)
            if let html = try? String(contentsOf: folder.appendingPathComponent(navPath), encoding: .utf8) {
                let doc = try SwiftSoup.parse(html)
                let navDir = (navPath as NSString).deletingLastPathComponent
                // Nur das Inhaltsverzeichnis: Die Datei enthält oft auch eine Seitenliste („[14]“) und Orientierungspunkte,
                // deren Einträge sonst zu Kapiteltiteln würden.
                let navs = try doc.select("nav").array()
                let toc = navs.first { ((try? $0.attr("epub:type")) ?? "").contains("toc") } ?? navs.first
                for a in try toc?.select("a[href]").array() ?? [] {
                    let href = try a.attr("href").components(separatedBy: "#")[0]
                    let path = normalize(navDir.isEmpty ? href : "\(navDir)/\(href.removingPercentEncoding ?? href)")
                    if tocTitles[path] == nil { tocTitles[path] = try a.text().trimmed }
                }
            }
        }
        if tocTitles.isEmpty, let ncx = manifest.values.first(where: { $0.type == "application/x-dtbncx+xml" }) {
            let ncxPath = rel(ncx.href)
            if let xml = try? String(contentsOf: folder.appendingPathComponent(ncxPath), encoding: .utf8) {
                let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
                let ncxDir = (ncxPath as NSString).deletingLastPathComponent
                for point in try doc.select("navPoint").array() {
                    guard let src = try point.select("content").first()?.attr("src"),
                          let label = try point.select("navLabel text").first()?.text() else { continue }
                    let href = src.components(separatedBy: "#")[0]
                    let path = normalize(ncxDir.isEmpty ? href : "\(ncxDir)/\(href.removingPercentEncoding ?? href)")
                    if tocTitles[path] == nil { tocTitles[path] = label.trimmed }
                }
            }
        }

        // Spine
        let navID = manifest.values.first { $0.props.contains("nav") }?.id
        var paths: [String] = []
        for ref in try opf.select("itemref").array() {
            if try ref.attr("linear") == "no" { continue }
            let id = try ref.attr("idref")
            // Das Inhaltsverzeichnis-Dokument gehört nicht in den Lesefluss – die Kapitelliste zeigt die App selbst.
            guard id != navID, let item = manifest[id] else { continue }
            let path = rel(item.href)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) else { continue }
            paths.append(path)
        }
        guard !paths.isEmpty else { throw BabelError.epub(String(localized: "Das Buch enthält keine lesbaren Kapitel")) }

        let bookTitle = try meta("title")
        var spine: [EPUBBook.Item]
        if let merged = mergePages(paths, folder: folder, tocCount: tocTitles.count) {
            spine = merged
        } else {
            // Ohne Eintrag im Inhaltsverzeichnis: Überschrift oder Titel des Dokuments, sonst „Abschnitt n“.
            let own = paths.map { tocTitles[$0] == nil ? documentTitle(folder.appendingPathComponent($0)) : nil }
            // Ein Titel, den viele Dokumente teilen (Buchtitel, Name der Website), sagt nichts.
            var counts: [String: Int] = [:]
            for title in own.compactMap({ $0 }) { counts[title, default: 0] += 1 }
            spine = paths.enumerated().map { i, path in
                var title = tocTitles[path]
                if title == nil, let candidate = own[i], counts[candidate] == 1, candidate != bookTitle { title = candidate }
                return EPUBBook.Item(path: path, title: title ?? String(localized: "Abschnitt \(i + 1)"))
            }
        }

        // Cover
        var coverPath: String?
        if let c = manifest.values.first(where: { $0.props.contains("cover-image") }) {
            coverPath = rel(c.href)
        } else if let metaCover = try opf.select("meta[name=cover]").first()?.attr("content"), let c = manifest[metaCover] {
            coverPath = rel(c.href)
        }

        var summary = try meta("description")
        if let s = summary, s.contains("<") { summary = (try? SwiftSoup.parse(s).text()) ?? s }

        return EPUBBook(
            title: bookTitle, author: try meta("creator"), summary: summary,
            language: try meta("language"), spine: spine, coverPath: coverPath
        )
    }

    /// Erste Überschrift oder `<title>` eines Dokuments – ohne das ganze Dokument zu parsen (es können Hunderte sein).
    static func documentTitle(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 24_000)) ?? Data(), as: UTF8.self)
        func clean(_ html: String) -> String? {
            let text = html.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty || text.count > 90 ? nil : text
        }
        for pattern in [#"(?s)<h[1-3][^>]*>(.*?)</h[1-3]>"#, #"(?s)<title[^>]*>(.*?)</title>"#] {
            if let match = head.firstMatch(pattern)?[1], let title = clean(match) { return title }
        }
        return nil
    }

    /// Aus Scans erzeugte EPUBs (Internet Archive) haben eine winzige Datei je Buchseite und kein Inhaltsverzeichnis:
    /// Hunderte „Kapitel“ von einer Bildschirmseite, jede Seite ein einziger Absatz, der mitten im Satz endet.
    /// Solche Bücher werden zu größeren Abschnitten zusammengelegt und der Text wieder lesbar gemacht (`ScanText`).
    /// Gibt `nil` zurück, wenn das Buch nicht so aufgebaut ist.
    static func mergePages(_ paths: [String], folder: URL, tocCount: Int) -> [EPUBBook.Item]? {
        guard paths.count >= 40, tocCount * 10 < paths.count else { return nil }
        let fm = FileManager.default
        let sizes = paths.map { ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent($0).path))?[.size] as? Int) ?? 0 }
        // Echte Kapitel sind im Schnitt deutlich größer als 8 KB.
        guard sizes.reduce(0, +) / paths.count < 8_000 else { return nil }

        func body(_ html: String) -> String {
            guard let open = html.range(of: "<body", options: .caseInsensitive),
                  let start = html[open.upperBound...].firstIndex(of: ">"),
                  let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) else { return "" }
            return String(html[html.index(after: start)..<end.lowerBound])
        }

        // Alle Seiten lesen: reiner Text (ein Absatz ohne weitere Tags) oder etwas anderes (Bilder, Tabellen …).
        var head = ""
        var pages: [(text: String?, raw: String)] = []
        for path in paths {
            guard let html = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { pages.append((nil, "")); continue }
            if head.isEmpty, let end = html.range(of: "</head>", options: .caseInsensitive) { head = String(html[..<end.upperBound]) }
            // Das Archive vermerkt Seiten, auf denen die Texterkennung unsicher war. Den Vermerk braucht beim Lesen niemand;
            // ist die Seite ein Bild (Umschlag, Illustration), ist ihr „Text“ nur Buchstabensalat aus dem Bild – dann bleibt das Bild allein.
            var content = body(html)
            var accuracy = 100.0
            if let note = content.firstMatch(#"<b>\s*The text on this page is estimated to be only\s*([\d.]+)%[^<]*</b>"#) {
                content = content.replacingOccurrences(of: note[0], with: "")
                accuracy = Double(note[1]) ?? 100
            }
            let letters = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).filter { !$0.isWhitespace }.count
            let hasPicture = content.range(of: "<img", options: .caseInsensitive) != nil
            if hasPicture, accuracy < 75 || letters < 200 {
                // Bildseite: Der „Text“ ist die Erkennung der Schrift im Bild selbst.
                content = content.allMatches(#"<img\b[^>]*>"#).map { $0[0].hasSuffix("/>") ? $0[0] : String($0[0].dropLast()) + "/>" }.joined()
            } else if !hasPicture, accuracy < 75, letters < 400 {
                // Kurze, unsicher erkannte Seite ohne Bild: Umschlag, Schmutztitel, Stempel – nichts zum Lesen.
                content = ""
            }
            // Der Hinweis des Internet Archive zur automatischen Umwandlung ist kein Teil des Buchs.
            if content.contains("produced in EPUB format by the Internet Archive") { pages.append((nil, "")); continue }
            if let text = content.firstMatch(#"(?s)^\s*<p[^>]*>([^<]*)</p>\s*$"#)?[1] {
                pages.append((text, ""))
            } else {
                pages.append((nil, content))
            }
        }
        // Kopfzeilen, die auf den meisten Seiten wiederkehren („Seite 12 Buchtitel …“), stünden sonst mitten im Satz.
        // Dasselbe gilt für Fußzeilen am Seitenende.
        if let header = ScanText.runningHeader(pages.map(\.text)) {
            pages = pages.map { ($0.text.map { ScanText.strippingHeader($0, header) }, $0.raw) }
        }
        if let footer = ScanText.runningHeader(pages.map(\.text), atEnd: true) {
            pages = pages.map { ($0.text.map { ScanText.strippingHeader($0, footer, atEnd: true) }, $0.raw) }
        }
        let offset = ScanText.pageNumberOffset(pages.map(\.text))
        // Die Scans tragen keine brauchbare Sprachangabe (`lang="None"`) – ohne sie trennt der Reader nach englischen
        // Regeln („Fre-undschaft“). Sprache aus dem Text bestimmen; ist sie unklar, gar nicht trennen.
        let sample = pages.compactMap(\.text).filter { $0.count > 200 }.dropFirst(5).prefix(12).joined(separator: " ")
        let language = NLLanguageRecognizer.dominantLanguage(for: String(sample.prefix(6_000)))?.rawValue
        let bodyTag = language.map { "<body lang=\"\($0)\">" } ?? "<body style=\"-webkit-hyphens: manual; hyphens: manual;\">"

        guard let directory = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return nil }
        if head.isEmpty { head = "<html><head><meta charset=\"utf-8\"/></head>" }
        var items: [EPUBBook.Item] = []
        var section: [String] = [], characters = 0, images = 0, firstPage = 1
        var carry = ""

        func close(at lastPage: Int) -> Bool {
            defer { section = []; characters = 0; images = 0; firstPage = lastPage + 1 }
            guard !section.isEmpty else { return true }
            let name = String(format: "babel-sec-%04d.xhtml", items.count + 1)
            let path = directory.isEmpty ? name : "\(directory)/\(name)"
            let document = head + bodyTag + section.joined(separator: "\n") + "</body></html>"
            guard (try? Data(document.utf8).write(to: folder.appendingPathComponent(path), options: .atomic)) != nil else { return false }
            let title = firstPage == lastPage ? String(localized: "Seite \(firstPage)") : String(localized: "Seiten \(firstPage)–\(lastPage)")
            items.append(EPUBBook.Item(path: path, title: title))
            return true
        }
        func emit(_ paragraphs: [String]) {
            for paragraph in paragraphs where !paragraph.isEmpty {
                section.append("<p>\(paragraph)</p>")
                characters += paragraph.count
            }
        }

        for (index, page) in pages.enumerated() {
            if let text = page.text {
                let cleaned = ScanText.strippingPageNumber(text, page: index, offset: offset)
                let joined = ScanText.join(carry, cleaned)
                // Bis zum letzten Satzende ausgeben, der angefangene Satz wandert auf die nächste Seite.
                let (complete, rest) = ScanText.splitAtLastSentenceEnd(joined)
                carry = rest
                // Seiten ganz ohne Satzende (Listen, Tabellen): nicht endlos ansammeln.
                if complete.isEmpty, carry.count > 2_500 { emit([carry]); carry = "" }
                emit(ScanText.paragraphs(complete))
            } else if !page.raw.isEmpty {
                let hasText = page.raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).contains { !$0.isWhitespace }
                let pictureCount = page.raw.components(separatedBy: "<img").count - 1
                guard hasText || pictureCount > 0 else { continue }
                if !carry.isEmpty { emit([carry]); carry = "" }
                // Bilder erst laden, wenn sie in Sicht kommen – ein Abschnitt kann Dutzende enthalten.
                section.append("<div class=\"babel-page\">\(page.raw.replacingOccurrences(of: "<img ", with: "<img loading=\"lazy\" decoding=\"async\" "))</div>")
                characters += page.raw.count / 2
                images += pictureCount
            }
            // Etwa 40.000 Zeichen oder 24 Bilder je Abschnitt.
            if characters >= 40_000 || images >= 24 {
                guard close(at: index + 1) else { return nil }
            }
        }
        if !carry.isEmpty { emit([carry]) }
        guard close(at: pages.count) else { return nil }
        return items.isEmpty ? nil : items
    }

    /// "OEBPS/Text/../Images/a.jpg" → "OEBPS/Images/a.jpg"
    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(part)
        }
        return out.joined(separator: "/")
    }
}

/// Text aus gescannten Seiten wieder lesbar machen. Die automatische Umwandlung liefert je Buchseite einen Absatz:
/// Seitenzahlen stehen mitten im Text, Sätze brechen am Seitenende ab, Absätze und Dialoge sind verloren.
/// Alles hier sind vorsichtige Näherungen – am Wortlaut wird nichts geändert, nur an Umbrüchen.
enum ScanText {
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?…]["”’»)\]]*(?=\s|$)"#)
    private static let openingQuotes: Set<Character> = ["“", "\"", "„", "«", "‘", "「"]

    /// Seitenzahl am Anfang oder Ende einer Seite („56 Erstes Buch …“ / „… 57“).
    private static func pageNumbers(_ text: String) -> [Int] {
        var found: [Int] = []
        if let n = text.firstMatch(#"^\s*(\d{1,4})\s"#)?[1], let value = Int(n) { found.append(value) }
        if let n = text.firstMatch(#"\s(\d{1,4})\s*$"#)?[1], let value = Int(n) { found.append(value) }
        return found
    }

    /// Wörter am Seitenanfang (oder -ende) mit Ziffern als „#“ – so sind „Page 12 Titel“ und „Page 13 Titel“ gleich.
    private static func edgeWords(_ text: String, _ count: Int, atEnd: Bool) -> [String] {
        let words = (atEnd ? Substring(text.suffix(160)) : text.prefix(160)).split(whereSeparator: \.isWhitespace)
        return (atEnd ? Array(words.suffix(count)) : Array(words.prefix(count))).map {
            $0.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        }
    }

    /// Wiederkehrende Kopf- oder Fußzeile: die längste Wortfolge (2–8 Wörter), mit der mindestens 40 % der Textseiten
    /// beginnen bzw. enden.
    static func runningHeader(_ pages: [String?], atEnd: Bool = false) -> [String]? {
        let texts = pages.compactMap { $0 }.filter { $0.count > 40 }
        guard texts.count >= 20 else { return nil }
        let edges = texts.map { edgeWords($0, 8, atEnd: atEnd) }
        for length in stride(from: 8, through: 2, by: -1) {
            var counts: [[String]: Int] = [:]
            for words in edges where words.count >= length {
                counts[atEnd ? Array(words.suffix(length)) : Array(words.prefix(length)), default: 0] += 1
            }
            if let best = counts.max(by: { $0.value < $1.value }), best.value * 5 >= texts.count * 2 { return best.key }
        }
        return nil
    }

    static func strippingHeader(_ text: String, _ header: [String], atEnd: Bool = false) -> String {
        guard edgeWords(text, header.count, atEnd: atEnd) == header else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        return (atEnd ? words.dropLast(header.count) : words.dropFirst(header.count)).joined(separator: " ")
    }

    /// Abstand zwischen gedruckter Seitenzahl und Position im Buch – wenn er bei vielen Seiten gleich ist,
    /// sind diese Zahlen Seitenzahlen und keine Zahlen aus dem Text.
    static func pageNumberOffset(_ pages: [String?]) -> Int? {
        var counts: [Int: Int] = [:]
        var textPages = 0
        for (index, text) in pages.enumerated() {
            guard let text else { continue }
            textPages += 1
            for number in Set(pageNumbers(text)) { counts[number - index, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), textPages >= 20, best.value * 4 >= textPages else { return nil }
        return best.key
    }

    static func strippingPageNumber(_ text: String, page: Int, offset: Int?) -> String {
        var result = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let offset else { return result }
        let number = String(page + offset)
        if result.hasPrefix(number + " ") { result = String(result.dropFirst(number.count + 1)) }
        if result.hasSuffix(" " + number) { result = String(result.dropLast(number.count + 1)) }
        return result
    }

    /// Seitenende und Seitenanfang verbinden; ein am Seitenende getrenntes Wort wird wieder eins.
    static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        if first.hasSuffix("-"), first.count > 1, first.dropLast().last?.isLetter == true, second.first?.isLowercase == true {
            return first.dropLast() + second
        }
        return first + " " + second
    }

    /// Teilt hinter dem letzten Satzende: (vollständige Sätze, angefangener Rest).
    static func splitAtLastSentenceEnd(_ text: String) -> (complete: String, rest: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let last = sentenceEnd.matches(in: text, range: range).last, let end = Range(last.range, in: text)?.upperBound else {
            return ("", text)
        }
        return (String(text[..<end]), String(text[end...]).trimmed)
    }

    /// Absätze aus einem Seitentext: Ein neuer Absatz beginnt, wo nach einem Satzende wörtliche Rede einsetzt,
    /// und spätestens nach rund 700 Zeichen am nächsten Satzende – eine ganze Seite am Stück liest sich auf dem iPhone schlecht.
    static func paragraphs(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var sentences: [Substring] = []
        var start = text.startIndex
        for match in sentenceEnd.matches(in: text, range: range) {
            guard let end = Range(match.range, in: text)?.upperBound, end > start else { continue }
            sentences.append(text[start..<end])
            start = end
        }
        if start < text.endIndex { sentences.append(text[start...]) }

        var result: [String] = []
        var current = ""
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let startsSpeech = trimmed.first.map(openingQuotes.contains) ?? false
            if !current.isEmpty, startsSpeech || current.count >= 700 {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? trimmed : " " + trimmed
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
