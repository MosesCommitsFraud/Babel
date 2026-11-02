import SwiftUI
import UIKit
import CryptoKit
import ImageIO

/// Verkleinerte, schon dekodierte Bilder. Ein EPUB-Cover hat oft 1600 px – angezeigt werden höchstens ~300.
enum Thumbnail {
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    /// Längste Kante in Pixeln für eine Anzeigegröße in Punkten (Retina ×3, auf Stufen gerundet, damit sich Größen den Cache teilen).
    static func pixels(for points: CGFloat) -> Int {
        let raw = Int(points * 3)
        return [120, 240, 360, 540].first { $0 >= raw } ?? 540
    }

    static func cached(_ url: URL, pixels: Int) -> UIImage? {
        memory.object(forKey: "\(url.path)#\(pixels)" as NSString)
    }

    /// Lädt und verkleinert im Hintergrund.
    static func load(_ url: URL, pixels: Int) async -> UIImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return downsample(source, pixels: pixels)
        }.value
        if let image { memory.setObject(image, forKey: "\(url.path)#\(pixels)" as NSString) }
        return image
    }

    /// Aus Daten (Netz/Festplatte) verkleinern – ebenfalls schon dekodiert, damit das Scrollen nicht stockt.
    nonisolated static func downsample(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source, pixels: pixels)
    }

    nonisolated private static func downsample(_ source: CGImageSource, pixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Lokales Cover (EPUB, gespeicherte Geschichte) als Vorschaubild.
struct LocalThumbnail<Placeholder: View>: View {
    let url: URL
    let maxPoints: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    private var pixels: Int { Thumbnail.pixels(for: maxPoints) }

    var body: some View {
        Group {
            if let image = image ?? Thumbnail.cached(url, pixels: pixels) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if image == nil { image = await Thumbnail.load(url, pixels: pixels) }
        }
    }
}

/// Lädt Cover (FFN, Gutenberg) mit Speicher- und Festplatten-Cache.
/// FFN liegt hinter Cloudflare: erst normal mit den Cookies des WebViews, sonst per `fetch()` in der offenen FFN-Seite.
actor ImageLoader {
    static let shared = ImageLoader()

    /// NSCache ist threadsicher, deshalb auch außerhalb des Actors lesbar.
    private static let memory = NSCache<NSURL, UIImage>()
    private var running: [URL: Task<UIImage?, Never>] = [:]
    private var failed: [URL: Date] = [:]

    private static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(hash.prefix(32)))
    }

    nonisolated func cached(_ url: URL) -> UIImage? {
        Self.memory.object(forKey: url as NSURL)
    }

    func image(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        if let date = failed[url], Date().timeIntervalSince(date) < 60 { return nil }
        if let task = running[url] { return await task.value }
        let task = Task<UIImage?, Never> { await Self.load(url) }
        running[url] = task
        let img = await task.value
        running[url] = nil
        if let img { Self.memory.setObject(img, forKey: url as NSURL) } else { failed[url] = Date() }
        return img
    }

    private static func load(_ url: URL) async -> UIImage? {
        let disk = file(for: url)
        // Cover werden höchstens ~104 pt breit gezeigt – verkleinert und vorab dekodiert spart Speicher und Ruckler.
        if let data = try? Data(contentsOf: disk), let img = Thumbnail.downsample(data, pixels: 540) { return img }

        var data: Data?
        let isFFN = url.host?.contains("fanfiction.net") == true
        var headers = ["Accept": "image/avif,image/webp,image/*,*/*;q=0.8"]
        if isFFN {
            await CookieSync.syncFromWebKitIfNeeded()
            headers["Referer"] = "https://www.fanfiction.net/"
        }
        if let (d, http) = try? await HTTPClient.shared.data(
            url,
            headers: headers,
            minInterval: 0.15,
            bucket: "img:\(url.host ?? "")"
        ), http.statusCode == 200, (http.mimeType ?? "").hasPrefix("image/") {
            data = d
        }
        if data == nil, isFFN {
            data = await WebFetcher.shared.fetchDataViaPage(url)
        }
        guard let data, let img = Thumbnail.downsample(data, pixels: 540) else { return nil }
        try? data.write(to: disk, options: .atomic)
        return img
    }
}

/// Zeigt ein Bild aus dem `ImageLoader`, solange es lädt den Platzhalter.
struct RemoteImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? ImageLoader.shared.cached(url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if image == nil { image = await ImageLoader.shared.image(url) }
        }
    }
}
