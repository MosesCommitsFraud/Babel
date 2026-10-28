import Foundation
import WebKit

/// Anmeldungen laufen in einem WebView. Danach werden die Cookies an URLSession übergeben.
@MainActor
enum CookieSync {
    private static let domains = ["archiveofourown", "fanfiction.net"]
    private static var lastSync = Date.distantPast

    static func webKitCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    static func syncFromWebKit() async {
        lastSync = Date()
        for cookie in await webKitCookies() where domains.contains(where: cookie.domain.contains) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Höchstens alle 20 Sekunden – wird nach jeder WebView-Seite aufgerufen.
    static func syncFromWebKitIfNeeded() async {
        guard Date().timeIntervalSince(lastSync) > 20 else { return }
        await syncFromWebKit()
    }

    static var isLoggedInToAO3: Bool {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        return cookies.contains { $0.domain.contains("archiveofourown") && ($0.name == "user_credentials" || $0.name == "remember_user_token") }
    }

    static func logoutAO3() async { await deleteCookies(matching: "archiveofourown") }
    static func logoutFFN() async { await deleteCookies(matching: "fanfiction.net", keep: ["cf_clearance", "__cf_bm"]) }

    private static func deleteCookies(matching domain: String, keep: Set<String> = []) async {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains(domain) && !keep.contains(cookie.name) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await webKitCookies() where cookie.domain.contains(domain) && !keep.contains(cookie.name) {
            await withCheckedContinuation { cont in store.delete(cookie) { cont.resume() } }
        }
    }
}
