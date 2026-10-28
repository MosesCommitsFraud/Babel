import SwiftUI
import WebKit

/// Lädt Seiten über einen unsichtbaren WKWebView. So kommt die App durch die
/// Cloudflare-Prüfung von FanFiction.net – wie ein normaler Safari-Besuch.
/// Wenn Cloudflare ein Häkchen verlangt, wird der WebView als Sheet eingeblendet.
@MainActor
final class WebFetcher: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = WebFetcher()

    let webView: WKWebView
    /// Unsichtbarer Parkplatz für den WebView, wenn er nicht im Sheet angezeigt wird.
    let parkingView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    @Published var needsUserInteraction = false
    private var userCancelledChallenge = false

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastNavigationError: Error?
    /// Wurde seit dem letzten Start schon eine neue Seite übernommen? Ohne das würde
    /// kurz nach `load` noch die alte Seite als „fertig“ gelten.
    private var navigationCommitted = false
    private var lastLoad = Date.distantPast

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = HTTPClient.userAgent
        super.init()
        webView.navigationDelegate = self
        parkingView.clipsToBounds = true
        parkingView.alpha = 0.01
        parkingView.isUserInteractionEnabled = false
        park()
    }

    func park() {
        parkingView.addSubview(webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    }

    func cancelChallenge() {
        userCancelledChallenge = true
        needsUserInteraction = false
    }

    // MARK: - Warteschlange (immer nur eine Seite gleichzeitig)

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: - Laden

    func load(_ url: URL, minInterval: Double = 1.2) async throws -> (html: String, url: URL) {
        await acquire()
        defer { release() }
        try await politePause(minInterval)
        start(url)
        return try await waitForPage(timeout: 30)
    }

    /// Führt ein Skript auf `pageURL` aus. Gibt das Skript "navigating" zurück, wird auf die neue Seite gewartet.
    func runScript(on pageURL: URL, body: String, arguments: [String: Any]) async throws -> (html: String, url: URL)? {
        await acquire()
        defer { release() }
        if webView.url?.absoluteString != pageURL.absoluteString {
            try await politePause(1.2)
            start(pageURL)
            _ = try await waitForPage(timeout: 30)
        }
        let before = webView.url?.absoluteString
        navigationCommitted = false
        let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) as? String
        guard result == "navigating" else { return nil }
        let started = Date()
        while webView.url?.absoluteString == before, !navigationCommitted, Date().timeIntervalSince(started) < 15 {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard webView.url?.absoluteString != before || navigationCommitted else { return nil }
        lastLoad = Date()
        return try await waitForPage(timeout: 30)
    }

    private func politePause(_ minInterval: Double) async throws {
        let wait = minInterval - Date().timeIntervalSince(lastLoad)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastLoad = Date()
    }

    private func start(_ url: URL) {
        lastNavigationError = nil
        userCancelledChallenge = false
        navigationCommitted = false
        var request = URLRequest(url: url)
        request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
    }

    private static let stateScript = """
    if (document.readyState !== 'complete') return 'loading';
    const t = document.title || '';
    if (/just a moment|einen moment|attention required|checking your browser|sicherheitsüberprüfung/i.test(t)) return 'challenge';
    if (document.querySelector('#challenge-form, #challenge-stage, #cf-challenge-running, .cf-turnstile, #turnstile-wrapper, #challenge-running')) return 'challenge';
    return 'ready';
    """

    private func waitForPage(timeout: Double) async throws -> (html: String, url: URL) {
        let started = Date()
        var challengeSince: Date?
        try await Task.sleep(for: .milliseconds(300))

        while true {
            try Task.checkCancellation()
            if let error = lastNavigationError {
                lastNavigationError = nil
                if (error as NSError).code != NSURLErrorCancelled { throw error }
            }
            if userCancelledChallenge {
                userCancelledChallenge = false
                throw BabelError.cloudflare
            }

            let state = (try? await webView.callAsyncJavaScript(Self.stateScript, arguments: [:], in: nil, contentWorld: .page)) as? String

            if state == "ready", !webView.isLoading, navigationCommitted {
                needsUserInteraction = false
                let html = (try? await webView.callAsyncJavaScript(
                    "return document.documentElement.outerHTML;", arguments: [:], in: nil, contentWorld: .page)) as? String ?? ""
                Task { await CookieSync.syncFromWebKitIfNeeded() }
                return (html, webView.url ?? URL(string: "about:blank")!)
            }

            if state == "challenge" {
                if challengeSince == nil { challengeSince = Date() }
                if let since = challengeSince, Date().timeIntervalSince(since) > 6, !needsUserInteraction {
                    needsUserInteraction = true
                }
            }

            let limit = needsUserInteraction ? 240 : timeout
            if Date().timeIntervalSince(started) > limit {
                needsUserInteraction = false
                throw state == "challenge" ? BabelError.cloudflare : BabelError.timeout
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// HTML der gerade offenen Seite (z. B. wenn sie Inhalte per Skript nachlädt).
    func currentHTML() async -> String? {
        try? await webView.callAsyncJavaScript("return document.documentElement.outerHTML;", arguments: [:], in: nil, contentWorld: .page) as? String
    }

    // MARK: - Dateien über die geladene Seite holen

    /// Lädt z. B. ein Cover mit `fetch()` innerhalb der gerade offenen FFN-Seite – mit deren Cookies.
    /// Blockiert die Warteschlange nicht; während einer Navigation gibt es einfach `nil`.
    func fetchDataViaPage(_ url: URL) async -> Data? {
        guard !webView.isLoading, let host = webView.url?.host, let target = url.host,
              host.hasSuffix(target.replacingOccurrences(of: "www.", with: "")) || target.hasSuffix(host.replacingOccurrences(of: "www.", with: "")) else { return nil }
        let script = """
        const r = await fetch(u, { credentials: 'include' });
        if (!r.ok) return null;
        const b = await r.blob();
        if (!b.type.startsWith('image/')) return null;
        return await new Promise(res => { const f = new FileReader(); f.onload = () => res(f.result); f.onerror = () => res(null); f.readAsDataURL(b); });
        """
        guard let dataURL = (try? await webView.callAsyncJavaScript(script, arguments: ["u": url.absoluteString], in: nil, contentWorld: .defaultClient)) as? String,
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationCommitted = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error
    }
}

/// Hält den unsichtbaren WebView in der View-Hierarchie (sonst arbeitet WebKit gedrosselt).
struct WebFetcherHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { WebFetcher.shared.parkingView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Zeigt den WebView sichtbar an, damit man die Cloudflare-Prüfung antippen kann.
struct ChallengeSheet: View {
    @ObservedObject private var fetcher = WebFetcher.shared

    var body: some View {
        NavigationStack {
            VisibleFetcherView()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Kurze Sicherheitsprüfung")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) {
                    Text("FanFiction.net möchte prüfen, dass du kein Bot bist. Tippe auf das Kästchen – danach geht's automatisch weiter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .padding(.horizontal)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen", systemImage: "xmark") { fetcher.cancelChallenge() }
                    }
                }
        }
        .interactiveDismissDisabled()
    }
}

private struct VisibleFetcherView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let webView = WebFetcher.shared.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        WebFetcher.shared.webView.autoresizingMask = []
        WebFetcher.shared.park()
    }
}
