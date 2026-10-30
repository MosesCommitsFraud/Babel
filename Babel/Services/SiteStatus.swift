import SwiftUI
import Observation

/// Merkt sich, ob AO3 oder FanFiction.net gerade erreichbar sind.
/// Gemeldet wird von HTTPClient/FFNService bei jeder Antwort; die Such-Ansichten zeigen dann ein Banner.
@MainActor
@Observable
final class SiteStatus {
    static let shared = SiteStatus()

    enum Site: String, CaseIterable {
        case ao3, ffn

        var name: String { self == .ao3 ? "AO3" : "FanFiction.net" }
        var homepage: URL {
            URL(string: self == .ao3 ? "https://archiveofourown.org/" : "https://www.fanfiction.net/")!
        }

        init?(host: String) {
            if host.contains("archiveofourown") { self = .ao3 }
            else if host.contains("fanfiction.net") { self = .ffn }
            else { return nil }
        }
    }

    struct Outage: Equatable {
        var reason: String
        var since: Date
    }

    private(set) var outages: [Site: Outage] = [:]
    private(set) var checking: Set<Site> = []
    private var lastCheck: [Site: Date] = [:]

    func outage(_ site: Site) -> Outage? { outages[site] }

    func reportOK(host: String) {
        guard let site = Site(host: host), outages[site] != nil else { return }
        withAnimation(.snappy) { outages[site] = nil }
    }

    func reportDown(host: String, reason: String) {
        guard let site = Site(host: host) else { return }
        withAnimation(.snappy) { outages[site] = Outage(reason: reason, since: outages[site]?.since ?? Date()) }
    }

    /// Ist eine Antwort ein Ausfall? 5xx und Cloudflares 52x ja – 403 (Cloudflare-Prüfung) und 429 (Bremse) nicht.
    nonisolated static func isOutage(status: Int) -> Bool { status >= 500 }

    nonisolated static func reason(status: Int) -> String {
        switch status {
        case 502, 504, 522, 524: String(localized: "antwortet nicht (Fehler \(status))")
        case 503: String(localized: "ist überlastet oder in Wartung (Fehler 503)")
        case 520...530: String(localized: "ist hinter Cloudflare nicht erreichbar (Fehler \(status))")
        default: String(localized: "hat einen Serverfehler (Fehler \(status))")
        }
    }

    nonisolated static func reason(error: Error) -> String? {
        guard let e = error as? URLError else { return nil }
        switch e.code {
        case .timedOut: return String(localized: "antwortet nicht (Zeitüberschreitung)")
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return String(localized: "ist nicht erreichbar")
        case .notConnectedToInternet: return nil // Das liegt am Gerät, nicht an der Seite.
        default: return nil
        }
    }

    /// Kurzer Test, höchstens alle 2 Minuten (oder sofort mit `force`).
    func check(_ site: Site, force: Bool = false) async {
        if !force, let last = lastCheck[site], Date().timeIntervalSince(last) < 120 { return }
        guard !checking.contains(site) else { return }
        checking.insert(site)
        lastCheck[site] = Date()
        defer { checking.remove(site) }
        var request = URLRequest(url: site.homepage)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        do {
            let (_, response) = try await HTTPClient.shared.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if Self.isOutage(status: status) { reportDown(host: site.homepage.host!, reason: Self.reason(status: status)) }
            else { reportOK(host: site.homepage.host!) }
        } catch {
            if let reason = Self.reason(error: error) { reportDown(host: site.homepage.host!, reason: reason) }
        }
    }
}

/// Glas-Banner „AO3 ist gerade nicht erreichbar“ mit „Erneut prüfen“.
struct SiteStatusBanner: View {
    let site: SiteStatus.Site
    @State private var status = SiteStatus.shared

    var body: some View {
        Group {
            if let outage = status.outage(site) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(site.name) \(outage.reason)")
                            .font(.footnote.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Seit \(outage.since.formatted(date: .omitted, time: .shortened)) – Suchen und Laden klappen gerade evtl. nicht.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        Task { await status.check(site, force: true) }
                    } label: {
                        if status.checking.contains(site) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Erneut prüfen")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await status.check(site) }
    }
}

extension View {
    /// Zeigt oben das Ausfall-Banner der Seite, falls sie gerade nicht erreichbar ist.
    func siteStatusBanner(_ site: SiteStatus.Site) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { SiteStatusBanner(site: site) }
    }
}
