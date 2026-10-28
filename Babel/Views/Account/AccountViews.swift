import SwiftUI
import SwiftData

// MARK: - AO3

struct AO3AccountView: View {
    @AppStorage("ao3.username") private var username = ""
    @State private var isChecking = false
    @State private var showLogin = false
    @State private var error: String?

    var body: some View {
        Form {
            if username.isEmpty {
                Section {
                    Label("Nicht angemeldet", systemImage: "person.crop.circle.badge.questionmark")
                    Button("Bei AO3 anmelden", systemImage: "person.crop.circle.badge.plus") { showLogin = true }
                } footer: {
                    Text("Mit Anmeldung siehst du hier deine Lesezeichen, „Später lesen“, Abos und deinen Verlauf und kannst sie in die Bibliothek übernehmen. Babel speichert kein Passwort – die Anmeldung läuft direkt auf archiveofourown.org.")
                }
                .themedRows()
            } else {
                Section {
                    LabeledContent("Angemeldet als", value: username)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .themedRows()
                Section("Deine Listen") {
                    ForEach(AO3Service.AccountList.allCases) { list in
                        NavigationLink {
                            AccountStoryList(title: list.label, importHint: importHint(list)) { page in
                                let result = try await AO3Service.accountList(list, user: username, page: page)
                                return (result.works, result.hasNext)
                            } configure: { story in
                                configure(story, for: list)
                            }
                        } label: {
                            Label(list.label, systemImage: list.symbol)
                        }
                    }
                }
                .themedRows()
                Section {
                    Button("Abmelden", role: .destructive) {
                        Task {
                            await CookieSync.logoutAO3()
                            username = ""
                        }
                    }
                }
                .themedRows()
            }
        }
        .themedBackground()
        .navigationTitle("AO3-Konto")
        .overlay { if isChecking { ProgressView() } }
        .task { await check() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await CookieSync.syncFromWebKit(); await check() } }) {
            WebLoginSheet(title: "AO3-Anmeldung", url: URL(string: "https://archiveofourown.org/users/login")!)
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        do {
            username = try await AO3Service.currentUsername() ?? ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importHint(_ list: AO3Service.AccountList) -> String {
        switch list {
        case .bookmarks: "Übernommene Lesezeichen werden als Favorit markiert."
        case .markedForLater: "Übernommene Werke bekommen den Status „Später lesen“."
        case .subscriptions: "Abonnierte Werke werden bei Updates automatisch geprüft."
        case .history: "Übernommene Werke bekommen den Status „Lese ich“."
        }
    }

    private func configure(_ story: Story, for list: AO3Service.AccountList) {
        switch list {
        case .bookmarks: story.isFavorite = true
        case .markedForLater: if !story.hasStarted { story.status = .planned }
        case .subscriptions: break
        case .history: if story.status == .planned || story.status == .none { story.status = .reading }
        }
    }
}

// MARK: - FanFiction.net

/// Anmeldestatus bei FFN und Abgleich der Favoriten/Follows mit der Bibliothek.
@MainActor
@Observable
final class FFNAccount {
    static let shared = FFNAccount()
    private static let key = "ffn.username"

    /// Leer = nicht angemeldet.
    private(set) var username = UserDefaults.standard.string(forKey: key) ?? ""
    private(set) var isChecking = false
    private(set) var isSyncing = false
    var isLoggedIn: Bool { !username.isEmpty }

    private func setUsername(_ name: String) {
        username = name
        UserDefaults.standard.set(name, forKey: Self.key)
    }

    /// Fragt FFN, wer angemeldet ist (steht oben auf jeder Seite).
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await CookieSync.syncFromWebKit()
        if let name = try? await FFNService.currentUsername() { setUsername(name) }
        else { setUsername("") }
    }

    /// Nach der Anmeldung: Status prüfen und Favoriten + Follows in die Bibliothek holen.
    func afterLogin(library: LibraryManager, context: ModelContext) async {
        let wasLoggedIn = isLoggedIn
        await check()
        if isLoggedIn && !wasLoggedIn { await sync(library: library, context: context) }
    }

    func sync(library: LibraryManager, context: ModelContext) async {
        guard isLoggedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        library.updateMessage = "Lade deine FFN-Favoriten …"
        var added = 0
        var failed = false
        for list in FFNService.AccountList.allCases {
            do {
                let stories = try await FFNService.accountList(list, username: username)
                added += library.importAll(stories, context: context) { Self.configure($0, for: list) }
            } catch {
                failed = true
            }
        }
        if added > 0 {
            library.updateMessage = added == 1 ? "1 Geschichte von FFN übernommen" : "\(added) Geschichten von FFN übernommen"
        } else {
            library.updateMessage = failed ? "FFN-Listen konnten nicht geladen werden" : "FFN-Bibliothek ist aktuell"
        }
    }

    func logout() async {
        await CookieSync.logoutFFN()
        setUsername("")
    }

    static func configure(_ story: Story, for list: FFNService.AccountList) {
        if list == .favorites { story.isFavorite = true }
        else if story.status == .planned || story.status == .none { story.status = .reading }
    }
}

struct FFNAccountView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @State private var account = FFNAccount.shared
    @State private var showLogin = false
    @State private var reloadToken = UUID()

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(account.isLoggedIn ? "Angemeldet als \(account.username)" : "Nicht angemeldet",
                          systemImage: account.isLoggedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    Spacer()
                    if account.isChecking { ProgressView() }
                }
                if account.isLoggedIn {
                    Button {
                        Task { await account.sync(library: library, context: context) }
                    } label: {
                        Label(account.isSyncing ? "Wird abgeglichen …" : "Favoriten & Follows in die Bibliothek", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(account.isSyncing)
                } else {
                    Button("Bei FanFiction.net anmelden", systemImage: "person.crop.circle.badge.plus") { showLogin = true }
                }
            } footer: {
                Text(account.isLoggedIn
                     ? "Favoriten werden als Favorit markiert, Follows bekommen „Lese ich“. Bereits vorhandene Geschichten bleiben, wie sie sind."
                     : "Die Anmeldung läuft direkt auf fanfiction.net. Danach holt Babel deine Favoriten und Follows automatisch in die Bibliothek. Babel speichert kein Passwort.")
            }
            .themedRows()

            if account.isLoggedIn {
                Section("Deine Listen") {
                    ForEach(FFNService.AccountList.allCases) { list in
                        NavigationLink {
                            AccountStoryList(title: list.label,
                                             importHint: list == .favorites ? "Übernommene Favoriten werden als Favorit markiert." : "Übernommene Follows bekommen den Status „Lese ich“.") { page in
                                guard page == 1 else { return ([], false) }
                                return (try await FFNService.accountList(list, username: account.username), false)
                            } configure: { story in
                                FFNAccount.configure(story, for: list)
                            }
                            .id(reloadToken)
                        } label: {
                            Label(list.label, systemImage: list.symbol)
                        }
                    }
                }
                .themedRows()

                Section {
                    Button("Abmelden", role: .destructive) {
                        Task { await account.logout() }
                    }
                }
                .themedRows()
            }
        }
        .themedBackground()
        .navigationTitle("FFN-Konto")
        .task { await account.check() }
        .sheet(isPresented: $showLogin, onDismiss: {
            Task {
                await account.afterLogin(library: library, context: context)
                reloadToken = UUID()
            }
        }) {
            WebLoginSheet(title: "FFN-Anmeldung", url: URL(string: "https://www.fanfiction.net/login.php")!)
        }
    }
}

// MARK: - Gemeinsame Liste mit „Alle übernehmen“

struct AccountStoryList: View {
    let title: String
    var importHint: String
    let load: (Int) async throws -> ([RemoteStory], Bool)
    let configure: (Story) -> Void

    @Environment(\.modelContext) private var context
    @Environment(LibraryManager.self) private var library
    @State private var stories: [RemoteStory] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var error: String?
    @State private var didLoad = false

    var body: some View {
        List {
            if !stories.isEmpty {
                Text(importHint).font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
            }
            ForEach(stories) { story in
                NavigationLink(value: story) { StoryRow(story: story, showSummary: false) }
                    .remoteStoryActions(story)
            }
            .themedRows(grouped: false)
            if hasNext {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .themedRows(grouped: false)
                    .task { await loadPage(page + 1) }
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && stories.isEmpty {
                ProgressView("Lade \(title) …")
            } else if let error, stories.isEmpty {
                ErrorBanner(message: error) { Task { await loadPage(1) } }
            } else if didLoad && stories.isEmpty {
                ContentUnavailableView("Nichts gefunden", systemImage: "tray", description: Text("Diese Liste ist leer."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("Alle übernehmen", systemImage: "square.and.arrow.down.on.square") {
                        Task { await importAll() }
                    }
                    .disabled(stories.isEmpty)
                }
            }
        }
        .refreshable { await loadPage(1) }
        .task { if !didLoad { await loadPage(1) } }
    }

    private func loadPage(_ number: Int) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false; didLoad = true }
        do {
            let (items, next) = try await load(number)
            if number == 1 {
                stories = items
            } else {
                let known = Set(stories.map(\.id))
                stories += items.filter { !known.contains($0.id) }
            }
            page = number
            hasNext = next && !items.isEmpty
        } catch {
            if number == 1 { self.error = error.localizedDescription }
            hasNext = false
        }
    }

    /// Lädt erst alle restlichen Seiten (mit den üblichen Pausen), dann ab in die Bibliothek.
    private func importAll() async {
        isImporting = true
        defer { isImporting = false }
        var guardPages = 0
        while hasNext, guardPages < 100 {
            guardPages += 1
            let before = stories.count
            await loadPage(page + 1)
            if stories.count == before { break }
        }
        let added = library.importAll(stories, context: context, configure: configure)
        library.updateMessage = added == 1 ? "1 Geschichte übernommen" : "\(added) Geschichten übernommen"
    }
}
