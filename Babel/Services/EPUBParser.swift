import Foundation
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
                for a in try doc.select("nav a[href]").array() {
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
    /// Hunderte „Kapitel“ von einer Bildschirmseite. Solche Bücher werden zu größeren Abschnitten zusammengelegt,
    /// leere Seiten fallen weg. Gibt `nil` zurück, wenn das Buch nicht so aufgebaut ist.
    static func mergePages(_ paths: [String], folder: URL, tocCount: Int) -> [EPUBBook.Item]? {
        guard paths.count >= 40, tocCount * 10 < paths.count else { return nil }
        let fm = FileManager.default
        let sizes = paths.map { ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent($0).path))?[.size] as? Int) ?? 0 }
        let total = sizes.reduce(0, +)
        // Echte Kapitel sind im Schnitt deutlich größer als 8 KB.
        guard total / paths.count < 8_000 else { return nil }

        func body(_ html: String) -> String {
            guard let open = html.range(of: "<body", options: .caseInsensitive),
                  let start = html[open.upperBound...].firstIndex(of: ">"),
                  let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) else { return "" }
            return String(html[html.index(after: start)..<end.lowerBound])
        }
        func hasContent(_ body: String) -> Bool {
            if body.range(of: "<img", options: .caseInsensitive) != nil || body.range(of: "<svg", options: .caseInsensitive) != nil { return true }
            return body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .contains { !$0.isWhitespace }
        }

        // Etwa 60 KB Text je Abschnitt, mindestens 10 Seiten.
        let perPart = max(10, Int((Double(paths.count) * 60_000 / Double(max(total, 1))).rounded()))
        var items: [EPUBBook.Item] = []
        var index = 0
        while index < paths.count {
            let group = Array(paths[index..<min(index + perPart, paths.count)])
            var parts: [String] = []
            var head = ""
            for (offset, path) in group.enumerated() {
                guard let html = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { continue }
                // Den Kopf (Stylesheets) der ersten Seite übernehmen – alle Seiten liegen im selben Ordner.
                if head.isEmpty, let end = html.range(of: "</head>", options: .caseInsensitive) { head = String(html[..<end.upperBound]) }
                let content = body(html)
                if hasContent(content) { parts.append("<div class=\"babel-page\" id=\"babel-page-\(index + offset + 1)\">\(content)</div>") }
            }
            let first = index + 1, last = index + group.count
            index += group.count
            guard !parts.isEmpty, let directory = group.first.map({ ($0 as NSString).deletingLastPathComponent }) else { continue }
            if head.isEmpty { head = "<html><head><meta charset=\"utf-8\"/></head>" }
            let name = String(format: "babel-part-%04d.xhtml", items.count + 1)
            let path = directory.isEmpty ? name : "\(directory)/\(name)"
            let document = head + "<body>" + parts.joined(separator: "\n") + "</body></html>"
            guard (try? Data(document.utf8).write(to: folder.appendingPathComponent(path), options: .atomic)) != nil else { return nil }
            items.append(EPUBBook.Item(path: path, title: String(localized: "Seiten \(first)–\(last)")))
        }
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
