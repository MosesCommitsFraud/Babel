import Foundation
import SwiftSoup

/// Aktionen auf AO3 und FanFiction.net im Namen der angemeldeten Person:
/// AO3 Kudos, Lesezeichen und Abo; FFN Favorit und Follow.
enum SiteActions {
    // MARK: - AO3

    /// Was auf der Werkseite für die angemeldete Person schon gesetzt ist.
    struct AO3State: Sendable {
        var loggedIn = false
        var kudosGiven = false
        var bookmarked = false
        var subscribed = false
    }

    enum AO3Action: Sendable { case kudos, bookmark, removeBookmark, subscribe }

    static func ao3State(workID: String) async throws -> AO3State {
        let page = try await ao3WorkPage(workID)
        return try await Task.detached(priority: .userInitiated) { try parseState(page.html) }.value
    }

    /// Führt die Aktion aus (beim Abo: an/aus umschalten) und gibt den neuen Stand zurück.
    @discardableResult
    static func ao3Perform(_ action: AO3Action, workID: String) async throws -> AO3State {
        let page = try await ao3WorkPage(workID)
        let state = try parseState(page.html)
        guard state.loggedIn else { throw BabelError.loginRequired }
        let doc = try SwiftSoup.parse(page.html, page.url.absoluteString)
        if action == .removeBookmark {
            try await removeBookmark(doc, base: page.url)
            return try await ao3State(workID: workID)
        }
        let selector: String = switch action {
        case .kudos: "form#new_kudo"
        case .bookmark: "form#bookmark-form, form.new_bookmark, form[action$=\"/bookmarks\"]"
        case .subscribe, .removeBookmark: "li.subscribe form, form.ajax-create-destroy[action*=\"subscriptions\"]"
        }
        guard let form = try doc.select(selector).first() else {
            // Kein Lesezeichen-Formular, aber schon gesetzt → nichts zu tun.
            if action == .bookmark && state.bookmarked { return state }
            throw BabelError.parsing(String(localized: "AO3-Formular"))
        }
        try await submit(form, base: page.url)
        // AO3 braucht einen Moment – danach den neuen Stand lesen.
        var fresh = try await ao3State(workID: workID)
        if action == .kudos { fresh.kudosGiven = true }
        return fresh
    }

    /// Lesezeichen löschen: ID aus dem „Edit Bookmark“-Link, dann wie AO3s Löschen-Knopf (`_method=delete`).
    private static func removeBookmark(_ doc: Document, base: URL) async throws {
        guard let edit = try doc.select("a").array().first(where: { (try? $0.text().trimmed) == "Edit Bookmark" }),
              let id = try edit.attr("href").firstMatch(#"/bookmarks/(\d+)"#)?[1] else { return }
        let token = try doc.select("meta[name=csrf-token]").first()?.attr("content") ?? ""
        try await post(AO3Service.base.appendingPathComponent("bookmarks/\(id)"),
                       fields: [("_method", "delete"), ("authenticity_token", token)], referer: base)
    }

    private static func ao3WorkPage(_ workID: String) async throws -> (html: String, url: URL) {
        await CookieSync.syncFromWebKit()
        let url = AO3Service.workURL(workID, full: false)
        let (html, finalURL, status) = try await AO3Service.fetchHTML(url)
        guard status == 200 else { throw BabelError.http(status) }
        return (html, finalURL)
    }

    nonisolated static func parseState(_ html: String) throws -> AO3State {
        let doc = try SwiftSoup.parse(html)
        var state = AO3State()
        state.loggedIn = try !doc.select("#greeting a[href^=\"/users/\"]").isEmpty() || html.contains("logged-in")
        let user = try doc.select("#greeting a[href^=\"/users/\"]").first()?.text().trimmed ?? ""
        // Kudos: eigener Name steht in der Kudos-Liste (oder das Formular fehlt, weil schon vergeben).
        let kudosNames = try doc.select("#kudos a[href^=\"/users/\"]").array().map { try $0.text() }
        state.kudosGiven = !user.isEmpty && kudosNames.contains(user)
        state.bookmarked = try doc.select("a").array().contains { (try? $0.text().trimmed) == "Edit Bookmark" }
        if let button = try doc.select("li.subscribe input[type=submit], li.subscribe button").first() {
            let label = try button.attr("value").isEmpty ? button.text() : button.attr("value")
            state.subscribed = label.localizedCaseInsensitiveContains("Unsubscribe")
        }
        return state
    }

    /// Formular mit allen Feldern so abschicken, wie AO3 es gebaut hat (CSRF-Token inklusive).
    private static func submit(_ form: Element, base: URL) async throws {
        let action = try form.attr("action")
        guard let url = URL(string: action, relativeTo: base)?.absoluteURL else { throw BabelError.parsing("Formular-Ziel") }
        var fields: [(String, String)] = []
        for input in try form.select("input[name], textarea[name], select[name]").array() {
            let type = try input.attr("type").lowercased()
            if type == "checkbox" || type == "radio" { guard input.hasAttr("checked") else { continue } }
            let value: String
            if input.tagName() == "textarea" { value = try input.text() }
            else if input.tagName() == "select" { value = try input.select("option[selected]").first()?.attr("value") ?? input.select("option").first()?.attr("value") ?? "" }
            else { value = try input.attr("value") }
            fields.append((try input.attr("name"), value))
        }
        try await post(url, fields: fields, referer: base)
    }

    private static func post(_ url: URL, fields: [(String, String)], referer base: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        let (_, response) = try await HTTPClient.shared.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 200/201 oder Weiterleitung zurück zum Werk; 422 = Kudos schon vergeben (zählt als erledigt).
        guard (200..<400).contains(status) || status == 422 else { throw BabelError.http(status) }
    }

    // MARK: - FanFiction.net

    /// Aus FFNs Follows bzw. Favoriten entfernen – wie der „Delete“-Knopf auf der Konto-Seite
    /// (`POST /alert/story.php` bzw. `/favorites/story.php`, `action=remove-multi`, `rids[]`).
    static func ffnRemove(storyID: String, from list: FFNService.AccountList) async throws {
        let script = """
        const body = new URLSearchParams();
        body.append('action', 'remove-multi');
        body.append('rids[]', id);
        const r = await fetch(path, { method: 'POST', credentials: 'include',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
        const text = await r.text();
        if (/Login Required/i.test(text)) return 'login';
        return r.ok ? 'ok' : 'error';
        """
        let path = list == .follows ? "/alert/story.php" : "/favorites/story.php"
        let result = try await WebFetcher.shared.evaluate(onSite: FFNService.base, body: script,
                                                          arguments: ["id": storyID, "path": path]) as? String
        if result == "login" { throw BabelError.ffnLoginRequired }
        guard result == "ok" else { throw BabelError.http(500) }
    }

    /// Zu Follows/Favoriten hinzufügen. Gibt FFNs Bestätigungstext zurück.
    static func ffnFollowFav(storyID: String, follow: Bool, favorite: Bool) async throws -> String {
        let script = """
        if (typeof XUNAME === 'undefined' || !XUNAME) return JSON.stringify({ login: false });
        const body = new URLSearchParams({ storyid: String(storyid), userid: String(userid),
          authoralert: '0', storyalert: follow ? '1' : '0', favstory: favorite ? '1' : '0', favauthor: '0' });
        const r = await fetch('/api/ajax_subs.php', { method: 'POST', credentials: 'include',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', 'X-Requested-With': 'XMLHttpRequest' }, body });
        let data = {};
        try { data = await r.json(); } catch (e) { data = { error: true }; }
        return JSON.stringify({ login: true, ok: r.ok && !data.error, message: String(data.payload_data || '') });
        """
        let url = FFNService.chapterURL(storyID: storyID, number: 1)
        let raw = try await WebFetcher.shared.evaluate(on: url, body: script, arguments: ["follow": follow, "favorite": favorite]) as? String
        struct Result: Decodable { let login: Bool; let ok: Bool?; let message: String? }
        guard let data = raw?.data(using: .utf8), let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw BabelError.parsing("FanFiction.net")
        }
        guard result.login else { throw BabelError.ffnLoginRequired }
        guard result.ok == true else { throw BabelError.http(500) }
        // FFN schickt HTML-Schnipsel („<br>Story Alert“) – als Klartext.
        return (result.message ?? "").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
