import SwiftUI
import SwiftData
import WebKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = true

    @AppStorage("ao3.username") private var ao3User = ""
    @State private var ffn = FFNAccount.shared
    @State private var showAO3Login = false
    @State private var showFFNLogin = false
    @State private var showFFNCheck = false
    @State private var storage: Int64 = 0
    @State private var confirmClearHistory = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ThemeSettingsRow()
                }
                .themedRows()

                Section {
                    HStack {
                        Label("Archive of Our Own", systemImage: StorySource.ao3.symbol)
                        Spacer()
                        Text(ao3User.isEmpty ? "Nicht angemeldet" : ao3User).foregroundStyle(.secondary)
                    }
                    if ao3User.isEmpty {
                        Button("Bei AO3 anmelden", systemImage: "person.crop.circle.badge.plus") { showAO3Login = true }
                    } else {
                        Button("Bei AO3 abmelden", role: .destructive) {
                            Task {
                                await CookieSync.logoutAO3()
                                ao3User = ""
                            }
                        }
                    }
                    HStack {
                        Label("FanFiction.net", systemImage: StorySource.ffn.symbol)
                        Spacer()
                        if ffn.isChecking { ProgressView() }
                        else { Text(ffn.isLoggedIn ? ffn.username : "Nicht angemeldet").foregroundStyle(.secondary) }
                    }
                    if ffn.isLoggedIn {
                        Button("Bei FanFiction.net abmelden", role: .destructive) {
                            Task { await ffn.logout() }
                        }
                    } else {
                        Button("Bei FanFiction.net anmelden", systemImage: "person.crop.circle.badge.plus") { showFFNLogin = true }
                    }
                    Button("FanFiction.net-Prüfung manuell öffnen", systemImage: "checkmark.shield") { showFFNCheck = true }
                } header: {
                    Text("Konten")
                } footer: {
                    Text("Eine Anmeldung ist freiwillig. Damit holst du Lesezeichen, „Später lesen“ und Abos von AO3 bzw. Favoriten und Follows von FanFiction.net in die App (AO3- und FanFiction-Tab → Konto). Babel speichert keine Passwörter.")
                }
                .themedRows()

                Section("Lesen") {
                    NavigationLink("Darstellung im Reader") {
                        Form { ReaderSettingsControls() }.navigationTitle("Darstellung")
                    }
                }
                .themedRows()

                Section {
                    Toggle("Beim Start nach neuen Kapiteln suchen", isOn: $checkUpdatesOnLaunch)
                    LabeledContent("Offline-Speicher", value: ByteCountFormatter.string(fromByteCount: storage, countStyle: .file))
                    Button("Verlauf löschen", role: .destructive) { confirmClearHistory = true }
                } header: {
                    Text("Bibliothek")
                } footer: {
                    Text("„Verlauf löschen“ entfernt Geschichten, die du nur angesehen, aber nicht in die Bibliothek gelegt hast.")
                }
                .themedRows()

                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Babel lädt Seiten wie ein normaler Browser, mit Pausen zwischen den Anfragen, um AO3 und FanFiction.net nicht zu belasten. Bremst eine Seite (HTTP 429), wartet die App automatisch so lange, wie die Seite verlangt. Unterstütze die Autor:innen mit Kudos und Reviews auf der Originalseite.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
            .task {
                storage = ContentStore.totalSize()
                await ffn.check()
            }
            .sheet(isPresented: $showAO3Login, onDismiss: {
                Task {
                    await CookieSync.syncFromWebKit()
                    ao3User = (try? await AO3Service.currentUsername()) ?? ""
                }
            }) {
                WebLoginSheet(title: "AO3-Anmeldung", url: URL(string: "https://archiveofourown.org/users/login")!)
            }
            .sheet(isPresented: $showFFNLogin, onDismiss: { Task { await ffn.afterLogin(library: library, context: context) } }) {
                WebLoginSheet(title: "FFN-Anmeldung", url: URL(string: "https://www.fanfiction.net/login.php")!)
            }
            .sheet(isPresented: $showFFNCheck) {
                WebLoginSheet(title: "FanFiction.net", url: URL(string: "https://www.fanfiction.net/")!)
            }
            .confirmationDialog("Verlauf löschen?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    library.clearHistory(context: context)
                    storage = ContentStore.totalSize()
                }
            }
        }
    }
}

/// Sichtbarer Browser (teilt Cookies mit dem Hintergrund-Loader).
struct WebLoginSheet: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SimpleWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
    }
}

struct SimpleWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = HTTPClient.userAgent
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
