import SwiftUI
import SwiftData
import WebKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = true
    @AppStorage(HighlightSettings.key) private var highlightsEnabled = false
    @AppStorage(DefaultRating.key) private var defaultRating: DefaultRating = .all
    @AppStorage(StoryLanguage.key) private var defaultLanguage = ""

    @AppStorage("ao3.username") private var ao3User = ""
    @State private var ffn = FFNAccount.shared
    @State private var showAO3Login = false
    @State private var showFFNLogin = false
    @State private var showFFNCheck = false
    @State private var storage: Int64 = 0
    @State private var confirmClearHistory = false
    @AppStorage(UpdateNotifier.enabledKey) private var notifyNewChapters = false
    @AppStorage(UpdateNotifier.lastRunKey) private var lastNotifyRun: Double = 0
    @State private var notifier = UpdateNotifier.shared

    /// „0.23.6 (Build 47)“ – Version und Build aus `project.yml`.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "\(version) (Build \(build))")
    }

    private func toggleNotifications(_ on: Bool) {
        guard on else {
            notifyNewChapters = false
            UpdateNotifier.schedule()
            return
        }
        // Sofort umschalten, die iOS-Abfrage kommt danach.
        notifyNewChapters = true
        Task {
            if await notifier.requestPermission() { UpdateNotifier.schedule() }
        }
    }

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
                    Button("Sicherheitsprüfung von FanFiction.net öffnen", systemImage: "checkmark.shield") { showFFNCheck = true }
                } header: {
                    Text("Konten")
                } footer: {
                    Text("Optional, um Lesezeichen, Favoriten und Follows zu übernehmen. Babel speichert keine Passwörter.")
                }
                .themedRows()

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        LabeledContent {
                            Text(Locale.current.localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "de")?.capitalized ?? "")
                        } label: {
                            Label("Sprache", systemImage: "globe")
                        }
                    }
                }
                .themedRows()

                Section {
                    Picker("Standard-Rating", selection: $defaultRating) {
                        ForEach(DefaultRating.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Standard-Sprache", selection: $defaultLanguage) {
                        ForEach(StoryLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Suche")
                }
                .themedRows()

                Section {
                    Toggle(isOn: Binding(get: { notifyNewChapters }, set: { on in toggleNotifications(on) })) {
                        Label("Bei neuen Kapiteln benachrichtigen", systemImage: "bell.badge")
                    }
                    if notifyNewChapters && notifier.permission == .denied {
                        Button("Mitteilungen in iOS erlauben", systemImage: "gear") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    #if DEBUG
                    // Hintergrundaufgaben laufen im Simulator nicht – hier denselben Ablauf von Hand anstoßen.
                    if notifyNewChapters {
                        Button("Hintergrundprüfung jetzt ausführen (Debug)", systemImage: "ladybug") {
                            Task { await notifier.runBackgroundCheck(container: context.container) }
                        }
                    }
                    #endif
                    if notifyNewChapters && lastNotifyRun > 0 {
                        LabeledContent("Zuletzt im Hintergrund geprüft",
                                       value: Date(timeIntervalSince1970: lastNotifyRun).formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Mitteilungen")
                } footer: {
                    Text("Gilt für angefangene Geschichten. Wann geprüft wird, entscheidet iOS.")
                }
                .themedRows()

                CloudSyncSection()

                Section {
                    NavigationLink("Darstellung im Reader") {
                        Form { ReaderSettingsControls() }.navigationTitle("Darstellung")
                    }
                    Toggle("Markierungen und Notizen", isOn: $highlightsEnabled)
                } header: {
                    Text("Lesen")
                } footer: {
                    if highlightsEnabled {
                        Text("Text im Reader markieren und im Menü „Markieren“ oder „Notiz“ wählen. Tippen auf eine Markierung öffnet sie. Alle Markierungen einer Geschichte stehen auf ihrer Detailseite.")
                    }
                }
                .themedRows()

                Section {
                    Toggle("Beim Start nach neuen Kapiteln suchen", isOn: $checkUpdatesOnLaunch)
                    LabeledContent("Offline-Speicher", value: ByteCountFormatter.string(fromByteCount: storage, countStyle: .file))
                    Button("Verlauf löschen", role: .destructive) { confirmClearHistory = true }
                } header: {
                    Text("Bibliothek")
                }
                .themedRows()

                Section("Über") {
                    LabeledContent("Version", value: Self.versionText)
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
                await notifier.refreshPermission()
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
            } message: {
                Text("Entfernt Geschichten, die du nur angesehen, aber nicht in die Bibliothek gelegt hast.")
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
