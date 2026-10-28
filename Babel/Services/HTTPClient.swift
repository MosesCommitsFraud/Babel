import Foundation
import UIKit
import Observation

/// Schlanker HTTP-Client mit Höflichkeits-Pausen pro Host und Wiederholung bei 429/503.
final class HTTPClient: @unchecked Sendable {
    static let shared = HTTPClient()

    /// Gleicher User-Agent wie der WebView, damit Cloudflare-Cookies für beide gelten.
    /// Desktop-Safari (wie Safari auf dem iPad): Mit iPhone-Kennung leitet FanFiction.net
    /// teils auf m.fanfiction.net um, deren Seiten ganz anders aufgebaut sind.
    static let userAgent: String = {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "26"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Safari/605.1.15"
    }()

    let session: URLSession
    let limiter = RateLimiter()

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 40
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": "de-DE,de;q=0.9,en;q=0.8",
        ]
        session = URLSession(configuration: config)
    }

    /// - Parameter bucket: eigener Takt (z. B. für AO3-Vorschläge), sonst der Host.
    ///   Eine Sperre nach 429 gilt trotzdem immer für den ganzen Host.
    func data(_ url: URL, headers: [String: String] = [:], minInterval: Double = 0.8, bucket: String? = nil,
              retries: Int = 2, timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        let host = url.host ?? ""
        var attempt = 0
        while true {
            try await limiter.wait(host: host, bucket: bucket ?? host, interval: minInterval)
            var request = URLRequest(url: url)
            if let timeout { request.timeoutInterval = timeout }
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BabelError.http(-1) }

            if http.statusCode == 429 || http.statusCode == 503 || http.statusCode == 525 {
                let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(8 * (attempt + 1))
                let pause = min(max(retry, 2), 120)
                if http.statusCode == 429 { await limiter.block(host: host, for: pause) }
                if attempt < retries {
                    attempt += 1
                    if http.statusCode != 429 { try await Task.sleep(for: .seconds(pause)) }
                    continue
                }
                if http.statusCode == 429 { throw BabelError.rateLimited }
            }
            return (data, http)
        }
    }

    /// Lädt eine Seite als Text. Gibt auch die endgültige URL (nach Weiterleitungen) zurück.
    func html(_ url: URL, minInterval: Double = 0.8, timeout: TimeInterval? = nil) async throws -> (html: String, finalURL: URL, status: Int) {
        let (data, http) = try await self.data(url, headers: ["Accept": "text/html,application/xhtml+xml"], minInterval: minInterval, timeout: timeout)
        let text = String(decoding: data, as: UTF8.self)
        return (text, http.url ?? url, http.statusCode)
    }

    func download(_ url: URL, to destination: URL) async throws {
        try await limiter.wait(host: url.host ?? "", bucket: url.host ?? "", interval: 0.5)
        let (tmp, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BabelError.http(http.statusCode)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }
}

/// Verteilt Anfragen zeitlich: pro Takt-Gruppe ein Mindestabstand, und nach einem 429 wartet der ganze Host.
actor RateLimiter {
    private var next: [String: Date] = [:]
    private var blockedUntil: [String: Date] = [:]

    func wait(host: String, bucket: String, interval: Double) async throws {
        while let until = blockedUntil[host], until > Date() {
            try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
        }
        let now = Date()
        let slot = max(now, next[bucket] ?? now)
        next[bucket] = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
    }

    func block(host: String, for seconds: Double) async {
        let until = Date().addingTimeInterval(seconds)
        blockedUntil[host] = max(until, blockedUntil[host] ?? until)
        await RateLimitStatus.shared.report(host: host, until: until)
    }
}

/// Für die Anzeige: Welche Seite bremst gerade und wie lange noch?
@MainActor
@Observable
final class RateLimitStatus {
    static let shared = RateLimitStatus()
    private(set) var host: String?
    private(set) var until: Date?

    func report(host: String, until: Date) {
        self.host = host
        self.until = until
        Task {
            try? await Task.sleep(for: .seconds(max(until.timeIntervalSinceNow, 0) + 0.5))
            if let current = self.until, current <= Date() { self.host = nil; self.until = nil }
        }
    }

    var siteName: String {
        guard let host else { return "" }
        if host.contains("archiveofourown") { return "AO3" }
        if host.contains("fanfiction") { return "FanFiction.net" }
        if host.contains("gutenberg") { return "Project Gutenberg" }
        return host
    }
}
