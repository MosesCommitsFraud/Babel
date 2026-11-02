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
        /// Letzte Prüfung, die den Ausfall bestätigt hat.
        var checked: Date = Date()
        /// Offizielle Meldung (AO3: otwstatus.org), z. B. „AO3 Down for Maintenance“.
        var official: String?
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
        let old = outages[site]
        withAnimation(.snappy) {
            outages[site] = Outage(reason: reason, since: old?.since ?? Date(), checked: Date(), official: old?.official)
        }
        if site == .ao3, old == nil { Task { await fetchOfficialStatus() } }
    }

    /// AO3 meldet Wartungen und Störungen auf otwstatus.org (Statuspage). Von dort kommt der echte Beginn.
    func fetchOfficialStatus() async {
        struct Summary: Decodable {
            struct Item: Decodable { let name: String; let status: String; let created_at: Date?; let scheduled_for: Date? }
            let incidents: [Item]
            let scheduled_maintenances: [Item]
        }
        guard let url = URL(string: "https://www.otwstatus.org/api/v2/summary.json"),
              let (data, _) = try? await HTTPClient.shared.session.data(from: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
        }
        guard let summary = try? decoder.decode(Summary.self, from: data) else { return }
        let open = (summary.incidents + summary.scheduled_maintenances).filter { $0.status != "resolved" && $0.status != "completed" && $0.status != "scheduled" }
        guard let item = open.first(where: { $0.name.localizedCaseInsensitiveContains("AO3") || $0.name.localizedCaseInsensitiveContains("Archive") }) ?? open.first,
              var outage = outages[.ao3] else { return }
        outage.official = item.name
        if let start = item.created_at ?? item.scheduled_for, start < outage.since { outage.since = start }
        outages[.ao3] = outage
    }

    /// Cloudflare-/Server-Fehlerseite statt Inhalt? Gibt den Fehlercode zurück.
    nonisolated static func errorPageCode(_ html: String) -> Int? {
        let head = String(html.prefix(20_000))
        guard head.localizedCaseInsensitiveContains("cloudflare") else { return nil }
        if let code = head.firstMatch(#"Error code:?\s*(5\d\d)"#)?[1].digitsInt { return code }
        if head.contains("cf-error-details") || head.contains("cf-wrapper"),
           let code = head.firstMatch(#"(5\d\d)"#)?[1].digitsInt { return code }
        return nil
    }

    /// Ist eine Antwort ein Ausfall? 5xx und Cloudflares 52x ja – 403 (Cloudflare-Prüfung) und 429 (Bremse) nicht.
    /// AO3 antwortet während Wartungen mit 418 „Request temporarily denied“.
    nonisolated static func isOutage(status: Int) -> Bool { status >= 500 || status == 418 }

    nonisolated static func reason(status: Int) -> String {
        switch status {
        case 418: String(localized: "ist gerade in Wartung")
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
        if site == .ao3, outages[.ao3] != nil { await fetchOfficialStatus() }
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
                        if let official = outage.official {
                            Text("Offiziell: \(official)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Seit \(Self.time(outage.since)) · zuletzt geprüft \(outage.checked.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
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
        // Solange die Seite weg ist: alle 2 Minuten von selbst nachsehen.
        .task(id: status.outage(site) != nil) {
            while status.outage(site) != nil {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await status.check(site, force: true)
            }
        }
    }

    /// Heute nur die Uhrzeit, sonst Datum + Uhrzeit.
    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

extension View {
    /// Zeigt oben das Ausfall-Banner der Seite, falls sie gerade nicht erreichbar ist.
    func siteStatusBanner(_ site: SiteStatus.Site) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { SiteStatusBanner(site: site) }
    }
}

/// Statt „Keine Treffer“: Die Seite ist gerade nicht erreichbar.
struct OutageEmptyView: View {
    let site: SiteStatus.Site
    let outage: SiteStatus.Outage
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("\(site.name) ist nicht erreichbar", systemImage: "exclamationmark.icloud")
        } description: {
            Text("\(site.name) \(outage.reason). Deshalb gibt es gerade keine Treffer – das liegt an der Seite, nicht an deiner Suche.")
        } actions: {
            Button("Nochmal versuchen", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.glass)
        }
    }
}
