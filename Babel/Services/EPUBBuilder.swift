import Foundation
import SwiftSoup

/// Baut aus gespeicherten Kapiteln (AO3/FFN) eine EPUB-Datei zum Teilen oder Sichern in „Dateien“.
enum EPUBBuilder {
    @MainActor
    static func build(_ story: Story) throws -> URL {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8))

        let count = story.knownChapterCount
        var manifest = ""
        var spine = ""
        var nav = ""
        for i in 0..<count {
            let file = String(format: "ch_%04d.xhtml", i)
            let title = story.title(ofChapter: i)
            let raw = (try? String(contentsOf: ContentStore.chapterURL(story, i), encoding: .utf8)) ?? ""
            zip.add("OEBPS/\(file)", Data(xhtml(title: title, body: bodyHTML(raw)).utf8))
            manifest += "<item id=\"c\(i)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i)\"/>\n"
            nav += "<li><a href=\"\(file)\">\(title.xmlEscaped)</a></li>\n"
        }

        let info = """
        <h1>\(story.title.xmlEscaped)</h1>
        <p><b>\(story.author.xmlEscaped)</b></p>
        <p>\(story.source.label) – <a href="\(story.urlString.xmlEscaped)">\(story.urlString.xmlEscaped)</a></p>
        \(story.fandoms.isEmpty ? "" : "<p>Fandom: \(story.fandoms.joined(separator: ", ").xmlEscaped)</p>")
        \(story.summary.isEmpty ? "" : "<blockquote>\(story.summary.xmlEscaped.replacingOccurrences(of: "\n", with: "<br/>"))</blockquote>")
        """
        zip.add("OEBPS/title.xhtml", Data(xhtml(title: story.title, body: info).utf8))
        zip.add("OEBPS/nav.xhtml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Inhalt</title></head>
        <body><nav epub:type="toc"><h1>Inhalt</h1><ol>
        \(nav)</ol></nav></body></html>
        """.utf8))

        let language = story.language.isEmpty ? "en" : String(story.language.prefix(2)).lowercased()
        zip.add("OEBPS/content.opf", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(story.key.xmlEscaped)</dc:identifier>
            <dc:title>\(story.title.xmlEscaped)</dc:title>
            <dc:creator>\(story.author.xmlEscaped)</dc:creator>
            <dc:language>\(language)</dc:language>
            <dc:source>\(story.urlString.xmlEscaped)</dc:source>
            <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()).prefix(19))Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
            \(manifest)
          </manifest>
          <spine><itemref idref="title"/>\(spine)</spine>
        </package>
        """.utf8))

        let name = story.title.replacingOccurrences(of: "[/\\\\:?*\"<>|]", with: "-", options: .regularExpression).prefix(80)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).epub")
        try zip.finish().write(to: url, options: .atomic)
        return url
    }

    /// Nur der Inhalt von <body> der gespeicherten Kapitel-Datei, ohne die eingefügte Überschrift.
    private static func bodyHTML(_ html: String) -> String {
        var body = html
        if let start = body.range(of: "<body>"), let end = body.range(of: "</body>", options: .backwards) {
            body = String(body[start.upperBound..<end.lowerBound])
        }
        // EPUB verlangt sauberes XHTML – SwiftSoup schreibt es so heraus.
        guard let doc = try? SwiftSoup.parseBodyFragment(body) else { return "" }
        _ = try? doc.select("h1.babel-title, script").remove()
        doc.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        return (try? doc.body()?.html()) ?? ""
    }

    private static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>\(title.xmlEscaped)</title></head>
        <body><h2>\(title.xmlEscaped)</h2>
        \(body)
        </body></html>
        """
    }
}

/// Minimaler ZIP-Schreiber (ohne Kompression – reicht für EPUB und hält `mimetype` unkomprimiert).
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(data.count)
        // Lokaler Header
        data.append(le32(0x04034b50)); data.append(le16(20)); data.append(le16(0x0800)); data.append(le16(0))
        data.append(le16(0)); data.append(le16(0x21))
        data.append(le32(crc)); data.append(le32(UInt32(content.count))); data.append(le32(UInt32(content.count)))
        data.append(le16(UInt16(name.count))); data.append(le16(0))
        data.append(name); data.append(content)
        // Zentralverzeichnis
        central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800))
        central.append(le16(0)); central.append(le16(0)); central.append(le16(0x21))
        central.append(le32(crc)); central.append(le32(UInt32(content.count))); central.append(le32(UInt32(content.count)))
        central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
        central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
        central.append(name)
        count += 1
    }

    func finish() -> Data {
        var out = data
        let start = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(count)); out.append(le16(count))
        out.append(le32(UInt32(central.count))); out.append(le32(start)); out.append(le16(0))
        return out
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

extension String {
    var xmlEscaped: String { htmlEscaped.replacingOccurrences(of: "'", with: "&apos;") }
}
