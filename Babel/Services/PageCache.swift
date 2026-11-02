import Foundation
import CryptoKit

/// Zwischenspeicher für AO3-Seiten (Suche, Listen, Werkangaben, Kommentare).
/// Frische Treffer kommen sofort ohne Netz; ist AO3 langsam oder weg, gibt es den letzten Stand (bis 7 Tage).
actor PageCache {
    static let ao3 = PageCache(name: "ao3")

    /// Wie lange eine gespeicherte Seite als Ersatz taugt, wenn die Seite nicht antwortet.
    static let staleLimit: TimeInterval = 7 * 24 * 3600

    private let folder: URL
    private var memory: [String: (date: Date, html: String)] = [:]
    private var order: [String] = []
    private let memoryLimit = 40

    init(name: String) {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pages-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder
        // Alte Seiten im Hintergrund wegräumen.
        Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(date) > Self.staleLimit { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// Gespeicherte Seite, wenn sie höchstens `maxAge` Sekunden alt ist.
    func html(for url: URL, maxAge: TimeInterval) -> String? {
        let key = Self.key(url)
        if let hit = memory[key] {
            return Date().timeIntervalSince(hit.date) <= maxAge ? hit.html : nil
        }
        let file = folder.appendingPathComponent(key)
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(date) <= maxAge,
              let data = try? Data(contentsOf: file) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        remember(key, date: date, html: html)
        return html
    }

    func store(_ html: String, for url: URL) {
        let key = Self.key(url)
        remember(key, date: Date(), html: html)
        try? Data(html.utf8).write(to: folder.appendingPathComponent(key), options: .atomic)
    }

    private func remember(_ key: String, date: Date, html: String) {
        if memory[key] == nil { order.append(key) }
        memory[key] = (date, html)
        while order.count > memoryLimit {
            memory[order.removeFirst()] = nil
        }
    }

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40) + ".html"
    }
}
