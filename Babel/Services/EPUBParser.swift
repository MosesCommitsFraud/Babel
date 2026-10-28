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
            throw BabelError.epub("META-INF/container.xml fehlt")
        }
        let container = try SwiftSoup.parse(containerXML, "", Parser.xmlParser())
        guard let opfPath = try container.select("rootfile").first()?.attr("full-path"), !opfPath.isEmpty else {
            throw BabelError.epub("Kein OPF gefunden")
        }
        let opfURL = folder.appendingPathComponent(opfPath)
        guard let opfXML = try? String(contentsOf: opfURL, encoding: .utf8) else { throw BabelError.epub("OPF nicht lesbar") }
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
        var spine: [EPUBBook.Item] = []
        for (i, ref) in try opf.select("itemref").array().enumerated() {
            if try ref.attr("linear") == "no" { continue }
            guard let item = manifest[try ref.attr("idref")] else { continue }
            let path = rel(item.href)
            spine.append(EPUBBook.Item(path: path, title: tocTitles[path] ?? "Abschnitt \(i + 1)"))
        }
        guard !spine.isEmpty else { throw BabelError.epub("Das Buch enthält keine lesbaren Kapitel") }

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
            title: try meta("title"), author: try meta("creator"), summary: summary,
            language: try meta("language"), spine: spine, coverPath: coverPath
        )
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
