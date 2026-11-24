import SwiftUI

/// Zählungen „Geschichten pro Sprache/Charakter/Genre“ je Liste.
///
/// FFN zählt nur einzeln (eine Anfrage je Wert, ~1 s) und lässt rund 100 Zählungen pro Minute zu.
/// Ein Fandom mit 460 Charakteren braucht also in jedem Fall Minuten – schneller wird es nur so:
/// - Es wird gezählt, sobald das Filterfenster aufgeht, nicht erst auf der Auswahlseite.
/// - Bei Charakteren nur die häufigen (`FFNService.characterSample`, höchstens `characterLimit`),
///   die Auswahl zeigt sie sofort oben; der Rest bleibt ohne Zahl.
/// - Unter FFNs Grenze bleiben und nach einer Pause weitermachen, statt in 429-Antworten zu laufen
///   (früher blieben dann alle weiteren Werte ohne Zahl).
/// - Zahlen bleiben 60 Tage liegen; nach 7 Tagen werden sie neu gezählt, die alten stehen solange da.
@MainActor
@Observable
final class FFNCountStore {
    static let shared = FFNCountStore()

    /// Eine Liste von Werten, die gezählt werden soll (ein Auswahlfeld des Filters).
    struct Request {
        var path: String
        var base: [String: String]
        var param: String
        var options: [FFNOption]
        var isCharacters: Bool
        var key: String { FFNCountStore.key(path, param) }
    }

    private struct Entry: Codable {
        var date: Date
        var counts: [String: Int]
        /// Zahlen der vorigen Zählung, solange neu gezählt wird.
        var old: [String: Int]?
        /// Geschätzte Häufigkeit aus den beliebtesten Geschichten (nur Charaktere).
        var rank: [String: Int]?
    }

    private struct Job {
        var request: Request
        var pending: [String]
        /// So viele von `pending` sind vorrangig (häufige Charaktere; bei Sprachen und Genres alle).
        var urgent: Int
        var needsSample: Bool
        var total: Int
    }

    private var entries: [String: Entry] = [:]
    private(set) var progress: [String: (done: Int, total: Int)] = [:]

    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var focused: String?
    private var runner: Task<Void, Never>?
    /// Zählt bei jedem `stop()` weiter, damit ein auslaufender Durchgang nichts mehr anfasst.
    private var generation = 0
    /// Zeitpunkte der letzten Zähl-Anfragen (für die Grenze pro Minute).
    private var stamps: [Date] = []
    private var blockedUntil = Date.distantPast

    private static let perMinute = 90
    /// Höchstens so viele Charaktere je Liste zählen (die häufigsten laut Stichprobe).
    private static let characterLimit = 40
    private static let refreshAfter: TimeInterval = 7 * 24 * 3600
    private static let keepFor: TimeInterval = 60 * 24 * 3600

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ffn-counts.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (key, var entry) in saved {
            let age = Date().timeIntervalSince(entry.date)
            guard age < Self.keepFor else { continue }
            if age > Self.refreshAfter {
                entry.old = (entry.old ?? [:]).merging(entry.counts) { _, new in new }
                entry.counts = [:]
                entry.date = Date()
            }
            entries[key] = entry
        }
    }

    nonisolated static func key(_ path: String, _ param: String) -> String { "\(path)|\(param)" }

    /// Zahlen zum Anzeigen: frisch gezählt, sonst der Stand von der letzten Zählung.
    func counts(_ key: String) -> [String: Int] {
        guard let entry = entries[key] else { return [:] }
        guard let old = entry.old else { return entry.counts }
        return old.merging(entry.counts) { _, new in new }
    }

    func rank(_ key: String) -> [String: Int] { entries[key]?.rank ?? [:] }

    func progressText(_ key: String) -> String? {
        progress[key].map { "\($0.done)/\($0.total)" }
    }

    /// Diese Liste zuerst zählen (ihre Auswahlseite ist offen).
    func focus(_ key: String?) { focused = key }

    /// Zählt alles, was in diesen Listen noch fehlt. Läuft, bis `stop()` kommt.
    func start(_ requests: [Request]) {
        for request in requests {
            let key = request.key
            guard jobs[key] == nil else { continue }
            let known = entries[key]?.counts ?? [:]
            let missing = request.options.map(\.value).filter { $0 != "0" && known[$0] == nil }
            guard !missing.isEmpty else { continue }
            jobs[key] = Job(request: request, pending: missing, urgent: request.isCharacters ? 0 : missing.count,
                            needsSample: request.isCharacters, total: missing.count)
            order.append(key)
            progress[key] = (0, missing.count)
        }
        guard runner == nil, !jobs.isEmpty else { return }
        let current = generation
        runner = Task { [weak self] in
            await self?.run(current)
            if self?.generation == current { self?.stop() }
        }
    }

    func stop() {
        runner?.cancel()
        generation += 1
        runner = nil
        jobs = [:]
        order = []
        progress = [:]
        save()
    }

    /// Erst alles Vorrangige (häufige Charaktere, Sprachen, Genres), dann der lange Rest der Charaktere –
    /// jeweils die offene Auswahlseite zuerst, sonst in der Reihenfolge des Filters.
    private func nextKey() -> String? {
        func isUrgent(_ key: String) -> Bool { jobs[key].map { $0.needsSample || $0.urgent > 0 } ?? false }
        if let focused, isUrgent(focused) { return focused }
        if let key = order.first(where: isUrgent) { return key }
        if let focused, jobs[focused] != nil { return focused }
        return order.first { jobs[$0] != nil }
    }

    /// Wie viele Zählungen gerade noch gehen. FFNs Grenze (Cloudflare) rechnet das vorige Minutenfenster
    /// anteilig mit: gemessen kam 429 nach 90 Anfragen, 60 s Pause und 47 weiteren. Deshalb zählt hier
    /// eine Anfrage 60 s voll und klingt dann über weitere 60 s ab – so bleibt es unter 100, egal wo
    /// FFNs Fenster gerade beginnt.
    private func allowance(at now: Date) -> Int {
        guard now >= blockedUntil else { return 0 }
        stamps.removeAll { now.timeIntervalSince($0) > 120 }
        let used = stamps.reduce(0.0) { $0 + min(1, (120 - now.timeIntervalSince($1)) / 60) }
        return Self.perMinute - Int(used.rounded(.up))
    }

    private func run(_ current: Int) async {
        while generation == current, let key = nextKey(), var job = jobs[key] {
            if job.needsSample {
                await sample(key, job: &job)
                guard generation == current else { return }
                jobs[key] = job.pending.isEmpty ? nil : job
                if job.pending.isEmpty { progress[key] = nil }
                continue
            }
            let now = Date()
            let allowance = allowance(at: now)
            if allowance <= 0 {
                try? await Task.sleep(for: .seconds(max(2, blockedUntil.timeIntervalSince(now))))
                continue
            }
            let batch = Array(job.pending.prefix(min(10, allowance)))
            let result = try? await FFNService.storyCounts(base: job.request.base, param: job.request.param, values: batch)
            stamps += Array(repeating: Date(), count: result?.sent ?? 0)
            var entry = entries[key] ?? Entry(date: Date(), counts: [:])
            entry.counts.merge(result?.counts ?? [:]) { _, new in new }
            entries[key] = entry
            guard generation == current else { return }
            guard let result else {
                jobs[key] = nil
                progress[key] = nil
                continue
            }
            if let wait = result.retryAfter {
                // Grenze erreicht: Was ohne Zahl blieb, kommt nach der Pause noch einmal dran.
                blockedUntil = Date().addingTimeInterval(wait + 1)
                job.pending.removeAll { result.counts[$0] != nil }
                job.urgent = max(0, job.urgent - result.counts.count)
            } else {
                // Einzelne Fehler nicht endlos wiederholen – die fehlen bis zum nächsten Öffnen.
                job.pending.removeFirst(batch.count)
                job.urgent = max(0, job.urgent - batch.count)
            }
            if job.pending.isEmpty {
                // Bei Charakteren ist nur ein Teil neu gezählt – die alten Zahlen der übrigen bleiben stehen.
                if !job.request.isCharacters { entry.old = nil }
                entries[key] = entry
                jobs[key] = nil
                progress[key] = nil
                save()
            } else {
                entries[key] = entry
                jobs[key] = job
                progress[key] = (job.total - job.pending.count, job.total)
            }
        }
    }

    /// Häufige Charaktere nach vorn: erst die schon einmal gezählten (nach alter Zahl),
    /// sonst nach der Schätzung aus den beliebtesten Geschichten.
    private func sample(_ key: String, job: inout Job) async {
        job.needsSample = false
        var entry = entries[key] ?? Entry(date: Date(), counts: [:])
        var weight = entry.old ?? [:]
        if weight.isEmpty {
            if entry.rank == nil {
                let names = Dictionary(job.request.options.map { ($0.text, $0.value) }, uniquingKeysWith: { a, _ in a })
                let found = await FFNService.characterSample(path: job.request.path, names: names)
                if !found.isEmpty { entry.rank = found }
            }
            weight = entry.rank ?? [:]
        }
        entries[key] = entry
        guard !weight.isEmpty else { return }
        let position = Dictionary(job.pending.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        job.pending.sort { a, b in
            let wa = weight[a] ?? 0, wb = weight[b] ?? 0
            return wa != wb ? wa > wb : (position[a] ?? 0) < (position[b] ?? 0)
        }
        // Nur die häufigen zählen: Jeder Charakter kostet eine Anfrage, alle 460 eines großen Fandoms
        // dauerten Minuten. Die übrigen stehen ohne Zahl darunter (nach Stichprobe, dann alphabetisch).
        job.pending = Array(job.pending.prefix { (weight[$0] ?? 0) > 0 }.prefix(Self.characterLimit))
        job.urgent = job.pending.count
        job.total = job.pending.count
        progress[key] = (0, job.total)
    }

    private func save() {
        let snapshot = entries, file = Self.file
        Task.detached(priority: .utility) {
            try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        }
    }
}

/// Fandoms, mit denen es Crossover gibt – je Fandom eine Liste, 7 Tage im Cache (Caches/ffn-cross).
/// Eine einzige Seite liefert alle Partner samt Anzahl; gezählt wird hier nichts einzeln.
@MainActor
@Observable
final class FFNCrossoverStore {
    static let shared = FFNCrossoverStore()

    struct Listing: Codable, Sendable {
        var date: Date
        var partners: [FFNCrossPartner]
        /// `false`: FFN liefert die Liste dieses Fandoms nicht – dann stehen hier alle Fandoms
        /// mit Crossovern, ohne Anzahl (nach Beliebtheit der Fandoms sortiert).
        var exact: Bool
    }

    private(set) var listings: [String: Listing] = [:]
    private(set) var loading: Set<String> = []
    private(set) var failed: Set<String> = []

    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ffn-cross", isDirectory: true)
    }

    private init() {}

    func load(_ ref: FFNCrossRef, force: Bool = false) async {
        guard !loading.contains(ref.id), force || listings[ref.id] == nil else { return }
        loading.insert(ref.id)
        failed.remove(ref.id)
        defer { loading.remove(ref.id) }
        let file = Self.folder.appendingPathComponent("\(ref.id).json")
        if !force, let cached = await Task.detached(priority: .userInitiated, operation: { () -> Listing? in
            guard let data = try? Data(contentsOf: file), let listing = try? JSONDecoder().decode(Listing.self, from: data),
                  Date().timeIntervalSince(listing.date) < 7 * 24 * 3600 else { return nil }
            return listing
        }).value {
            listings[ref.id] = cached
            return
        }
        do {
            var partners = try await FFNService.crossPartners(of: ref)
            let exact = !partners.isEmpty
            if !exact {
                let all = try await FFNService.crossFandoms()
                partners = await Task.detached(priority: .userInitiated) {
                    all.filter { $0.ref.id != ref.id }.sorted { $0.count > $1.count }
                        .map { FFNCrossPartner(name: $0.ref.name, path: ref.pairPath(with: $0.ref), count: nil) }
                }.value
            }
            guard !partners.isEmpty else { failed.insert(ref.id); return }
            let listing = Listing(date: Date(), partners: partners, exact: exact)
            listings[ref.id] = listing
            let folder = Self.folder
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? JSONEncoder().encode(listing).write(to: file, options: .atomic)
            }
        } catch {
            failed.insert(ref.id)
        }
    }
}

/// FFN-Filter wie auf der Website, übersichtlich gruppiert.
/// Charaktere sind in zwei Paaren angeordnet, jedes mit eigenem „Als Paar“-Schalter.
/// Wechselt die Crossover-Auswahl, lädt das Fenster die neue Seite gleich vorab: Deren Charaktere
/// (bei zwei Fandoms A/B aus dem einen, C/D aus dem anderen) stehen dann sofort zur Wahl.
struct FFNFilterSheet: View {
    /// Das Fandom, dessen Crossover zur Wahl stehen; ohne gibt es die Zeile nicht.
    let home: FFNCrossRef?
    let loadedCrossover: FFNCrossChoice
    /// Seite zu einer Crossover-Auswahl; `nil`, wenn es sie nicht gibt (z. B. ohne Crossover bei
    /// einem gespeicherten Crossover-Filter).
    let pathFor: (FFNCrossChoice) -> String?
    var onApply: ([String: String], [[String]], FFNCrossChoice, [FFNFilterSelect]) -> Void
    var onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    /// Als Paar markierte Charakterfelder, z. B. ["characterid1", "characterid3"] = A × C.
    @State private var pairs: [[String]]
    @State private var crossover: FFNCrossChoice
    /// Auswahlfelder, Pfad (Schlüssel der Zählungen) und Kontext der Seite, für die gerade gefiltert wird.
    @State private var filters: [FFNFilterSelect]
    @State private var pagePath: String
    @State private var context: FFNPageContext?
    /// Für welche Crossover-Auswahl `filters` gelten.
    @State private var filtersFor: FFNCrossChoice
    @State private var previewFailed = false
    private let original: (filters: [FFNFilterSelect], path: String, context: FFNPageContext?)

    init(filters: [FFNFilterSelect], pagePath: String, context: FFNPageContext?, home: FFNCrossRef?,
         crossover: FFNCrossChoice, pathFor: @escaping (FFNCrossChoice) -> String?, pairs: [[String]],
         onApply: @escaping ([String: String], [[String]], FFNCrossChoice, [FFNFilterSelect]) -> Void, onReset: @escaping () -> Void) {
        self.home = home
        self.loadedCrossover = crossover
        self.pathFor = pathFor
        self.onApply = onApply
        self.onReset = onReset
        original = (filters, pagePath, context)
        // Nicht in onAppear: das läuft nach jeder Auswahlseite erneut und würde die Auswahl zurücksetzen.
        _values = State(initialValue: Dictionary(filters.map { ($0.name, $0.selected) }, uniquingKeysWith: { a, _ in a }))
        let pm = filters.first { $0.name == "pm" }?.selected == "1"
        _pairs = State(initialValue: !pairs.isEmpty ? pairs : (pm ? [Self.pairNames[0]] : []))
        _crossover = State(initialValue: crossover)
        _filters = State(initialValue: filters)
        _pagePath = State(initialValue: pagePath)
        _context = State(initialValue: context)
        _filtersFor = State(initialValue: crossover)
    }

    private var canLeaveCrossover: Bool { pathFor(.none) != nil }

    private static let sortNames = ["sortid", "timerange", "timeid"]
    private static let pairNames = [["characterid1", "characterid2"], ["characterid3", "characterid4"]]

    private func filter(_ name: String) -> FFNFilterSelect? { filters.first { $0.name == name } }

    /// Charaktere und Welten gehören zur Seite: Solange die Seite der neuen Crossover-Auswahl noch lädt,
    /// passen die angezeigten nicht und bleiben ausgeblendet.
    private var crossoverChanged: Bool { crossover != filtersFor }

    /// Alle Crossover eines Fandoms: Charaktere werden dort nicht gezählt (nur bei zwei bestimmten Fandoms).
    private var isAllCrossovers: Bool { context.map { $0.isCrossover && !$0.isPair } ?? false }

    private var contentFilters: [FFNFilterSelect] {
        let used = Set(Self.sortNames + Self.pairNames.flatMap { $0 } + ["pm", "_pm"])
        return filters.filter { !$0.isExclusion && !used.contains($0.name) && !(crossoverChanged && FFNListModel.isListBound($0.name)) }
    }

    /// Alles, was gezählt wird – Charaktere zuerst, weil es dort am längsten dauert.
    private var countRequests: [FFNCountStore.Request] {
        var seen = Set<String>()
        let requests = filters.compactMap { f -> FFNCountStore.Request? in
            guard let param = FFNService.countParam(for: f.name, context: context) else { return nil }
            if isAllCrossovers, f.name.contains("characterid") { return nil }
            let request = FFNCountStore.Request(path: pagePath, base: context?.countBase ?? [:], param: param,
                                                options: f.options, isCharacters: f.name.contains("characterid"))
            return seen.insert(request.key).inserted ? request : nil
        }
        return requests.filter(\.isCharacters) + requests.filter { $0.param == "lan" } + requests.filter { $0.param == "g1" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sortierung") {
                    ForEach(Self.sortNames.compactMap(filter)) { row($0) }
                }
                .themedRows()

                if let home {
                    Section {
                        NavigationLink {
                            FFNCrossoverPicker(home: home, allowsNone: canLeaveCrossover, selection: $crossover)
                        } label: {
                            LabeledContent("Crossover", value: crossoverLabel)
                        }
                        if crossoverChanged && !previewFailed {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Lade Charaktere …").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        if crossoverChanged && previewFailed {
                            Text("Die Charaktere der neuen Auswahl konnten nicht geladen werden – tippe auf „Anwenden“ und öffne den Filter noch einmal.")
                        }
                    }
                    .themedRows()
                }

                Section("Inhalt") {
                    ForEach(contentFilters) { row($0) }
                }
                .themedRows()

                if !crossoverChanged {
                    if context?.isPair == true {
                        crossoverCharacters
                    } else {
                        ForEach(Array(Self.pairNames.enumerated()), id: \.offset) { index, names in
                            let selects = names.compactMap(filter)
                            if !selects.isEmpty {
                                Section {
                                    ForEach(selects) { row($0) }
                                    if filter("pm") != nil, selects.count == 2 {
                                        Toggle("Als Paar", isOn: pairBinding(names))
                                            .disabled(names.contains { (values[$0] ?? "0") == "0" })
                                    }
                                } header: {
                                    Text("Charaktere \(index == 0 ? "A + B" : "C + D")")
                                } footer: {
                                    if index == 0 {
                                        Text("„Als Paar“ zeigt nur Geschichten, in denen die beiden ein Pairing sind. Jedes Paar lässt sich einzeln einschalten.")
                                    }
                                }
                                .themedRows()
                            }
                        }
                    }
                }

                let exclusions = filters.filter { $0.isExclusion && !(crossoverChanged && FFNListModel.isListBound($0.name)) }
                if !exclusions.isEmpty {
                    Section("Ausschließen") {
                        ForEach(exclusions) { row($0) }
                    }
                    .themedRows()
                }
            }
            .themedBackground()
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") {
                        dismiss()
                        onReset()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anwenden", systemImage: "checkmark") {
                        var result = values
                        var pairs = activePairs
                        if crossoverChanged {
                            // Neue Seite noch nicht da: Charaktere/Welten der alten passen nicht zu ihr.
                            result = result.filter { !FFNListModel.isListBound($0.key) }
                            pairs = []
                        } else if filter("pm") != nil {
                            // FFN hat nur ein Pairing-Häkchen (für A+B bzw. C+D); welches Paar gemeint ist,
                            // filtert die App danach selbst. Paare über zwei Fandoms hinweg kennt FFN nicht –
                            // dann ohne Häkchen laden und nur hier filtern.
                            let fits = !pairs.isEmpty && pairs.allSatisfy { Self.pairNames.contains($0) }
                            result["pm"] = fits ? "1" : "0"
                        }
                        dismiss()
                        onApply(result, pairs, crossover, filters)
                    }
                }
            }
        }
        // Schon beim Öffnen zählen und die Crossover-Liste holen, nicht erst auf der Auswahlseite.
        .task {
            FFNCountStore.shared.start(countRequests)
            if let home { await FFNCrossoverStore.shared.load(home) }
        }
        .task(id: crossover) { await loadFilters(for: crossover) }
        .onDisappear { FFNCountStore.shared.stop() }
    }

    /// Holt die Auswahlfelder der Seite zur Crossover-Auswahl (zurück zur geladenen: sofort).
    /// Sortierung, Rating, Sprache usw. bleiben gewählt, Charaktere/Welten fangen leer an.
    private func loadFilters(for choice: FFNCrossChoice) async {
        guard choice != filtersFor else { return }
        previewFailed = false
        let page: (filters: [FFNFilterSelect], path: String, context: FFNPageContext?)
        if choice == loadedCrossover {
            page = original
        } else {
            guard let path = pathFor(choice) else { previewFailed = true; return }
            // Während die Seite lädt, nicht für die alte weiterzählen (beides läuft über denselben WebView).
            FFNCountStore.shared.stop()
            guard let result = try? await FFNService.list(url: FFNService.url(path: path)), !Task.isCancelled else {
                if !Task.isCancelled { previewFailed = true }
                return
            }
            let encoded = URLComponents(url: result.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? result.url.path
            page = (result.filters, encoded, result.context)
        }
        guard crossover == choice else { return }
        var kept = values.filter { !FFNListModel.isListBound($0.key) }
        for f in page.filters where FFNListModel.isListBound(f.name) || kept[f.name] == nil {
            // Was die Seite für Charaktere/Welten vorauswählt; die übrigen Felder behalten die Wahl.
            kept[f.name] = choice == loadedCrossover ? f.selected : (f.options.first?.value ?? "0")
        }
        values = kept
        pairs = choice == loadedCrossover ? pairs : []
        filters = page.filters
        pagePath = page.path
        context = page.context
        filtersFor = choice
        FFNCountStore.shared.stop()
        FFNCountStore.shared.start(countRequests)
    }

    private func pairBinding(_ names: [String]) -> Binding<Bool> {
        Binding(get: { pairs.contains(names) },
                set: { on in pairs.removeAll { $0 == names }; if on { pairs.append(names) } })
    }

    private static let characterNames = ["characterid1", "characterid2", "characterid3", "characterid4"]

    /// Paare, deren beide Charaktere gewählt sind.
    private var activePairs: [[String]] {
        pairs.filter { $0.allSatisfy { (values[$0] ?? "0") != "0" } }
    }

    private func chosenName(_ field: String) -> String? {
        guard let value = values[field], value != "0" else { return nil }
        return filter(field)?.options.first { $0.value == value }?.text
    }

    /// Crossover mit zwei Fandoms: Charaktere je Fandom, darunter beliebige Paare aus den gewählten –
    /// auch über die Fandoms hinweg (Harry P. × Edward).
    @ViewBuilder
    private var crossoverCharacters: some View {
        ForEach(Array(Self.pairNames.enumerated()), id: \.offset) { index, names in
            let selects = names.compactMap(filter)
            if !selects.isEmpty {
                Section(pairFandom(index) ?? (index == 0 ? String(localized: "Fandom A") : String(localized: "Fandom B"))) {
                    ForEach(selects) { row($0) }
                }
                .themedRows()
            }
        }
        if filter("pm") != nil || Self.characterNames.contains(where: { filter($0) != nil }) {
            let chosen = Self.characterNames.compactMap { field in chosenName(field).map { (field, $0) } }
            Section {
                if chosen.count < 2 {
                    Text("Wähle oben mindestens zwei Charaktere, dann lassen sie sich hier als Paar markieren.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(0..<chosen.count, id: \.self) { i in
                        ForEach(i + 1..<chosen.count, id: \.self) { j in
                            Toggle("\(chosen[i].1) × \(chosen[j].1)", isOn: pairBinding([chosen[i].0, chosen[j].0]))
                        }
                    }
                }
            } header: {
                Text("Pairings")
            } footer: {
                Text("Zeigt nur Geschichten, in denen die beiden ein Pairing sind – auch über beide Fandoms hinweg.")
            }
            .themedRows()
        }
    }

    /// Auf einer Crossover-Seite mit zwei Fandoms gehören A/B zum einen, C/D zum anderen.
    private func pairFandom(_ index: Int) -> String? {
        guard let context, context.isPair else { return nil }
        let id = index == 0 ? context.fandomID : context.partnerID
        return context.refs.first { $0.id == id }?.name
    }

    private var crossoverLabel: String {
        switch crossover {
        case .none: String(localized: "Keine")
        case .all: String(localized: "Alle")
        case .with(let partner): partner.name
        }
    }

    /// „All Characters (A)“ → „Charakter A“, „Genre (A): All“ → „Genre A“ usw.
    private func label(_ filter: FFNFilterSelect) -> String {
        let letters = ["characterid1": "A", "characterid2": "B", "characterid3": "C", "characterid4": "D",
                       "_characterid1": "A", "_characterid2": "B"]
        if let l = letters[filter.name] {
            return filter.isExclusion ? String(localized: "Ohne: Charakter \(l)") : String(localized: "Charakter \(l)")
        }
        switch filter.name {
        case "genreid1": return String(localized: "Genre A")
        case "genreid2": return String(localized: "Genre B")
        case "_genreid1": return String(localized: "Ohne: Genre")
        case "languageid": return String(localized: "Sprache")
        default: return filter.label
        }
    }

    @ViewBuilder
    private func row(_ filter: FFNFilterSelect) -> some View {
        let binding = Binding(
            get: { values[filter.name] ?? filter.selected },
            set: { values[filter.name] = $0 }
        )
        if filter.name == "_pm" {
            Toggle(isOn: Binding(get: { binding.wrappedValue == "1" }, set: { binding.wrappedValue = $0 ? "1" : "0" })) {
                Text("Kein Paar")
            }
        } else if let param = FFNService.countParam(for: filter.name, context: context) {
            NavigationLink {
                FFNCountedPicker(filter: filter, title: label(filter), selection: binding, countKey: FFNCountStore.key(pagePath, param))
            } label: {
                LabeledContent(label(filter), value: binding.wrappedValue == "0"
                               ? String(localized: "Alle")
                               : filter.options.first { $0.value == binding.wrappedValue }?.text ?? "")
            }
        } else {
            // Eigene Auswahlseite statt Menü – Menüs springen in langen Formularen weg.
            Picker(filter.label, selection: binding) {
                ForEach(filter.options) { Text($0.text).tag($0.value) }
            }
            .pickerStyle(.navigationLink)
        }
    }
}

/// Auswahlseite mit Anzahl Geschichten pro Eintrag, meiste zuerst (Sprachen, Charaktere, Genres).
/// Gezählt wird im `FFNCountStore`, angestoßen vom Filterfenster; solange Zahlen fehlen, stehen
/// die laut Stichprobe häufigen Einträge vorn.
struct FFNCountedPicker: View {
    let filter: FFNFilterSelect
    let title: String
    @Binding var selection: String
    let countKey: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var store = FFNCountStore.shared
    @State private var search = ""

    private func options(counts: [String: Int]) -> [FFNOption] {
        let all = filter.options.dropFirst()
        let q = search.trimmed.lowercased()
        let filtered = q.isEmpty ? Array(all) : all.filter { $0.text.lowercased().contains(q) }
        let rank = store.rank(countKey)
        return filtered.sorted { a, b in
            let ca = counts[a.value] ?? -1, cb = counts[b.value] ?? -1
            if ca != cb { return ca > cb }
            let ra = rank[a.value] ?? 0, rb = rank[b.value] ?? 0
            return ra != rb ? ra > rb : a.text.localizedStandardCompare(b.text) == .orderedAscending
        }
    }

    var body: some View {
        let counts = store.counts(countKey)
        List {
            if let first = filter.options.first {
                optionRow(FFNOption(value: first.value, text: String(localized: "Alle")), count: nil)
            }
            if let progress = store.progressText(countKey) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Zähle Geschichten … \(progress)").font(.footnote).foregroundStyle(.secondary)
                }
                .themedRows()
            }
            ForEach(options(counts: counts)) { option in
                optionRow(option, count: counts[option.value])
            }
        }
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: filter.options.count > 15 ? .always : .automatic))
        .onAppear { store.focus(countKey) }
        .onDisappear { store.focus(nil) }
    }

    private func optionRow(_ option: FFNOption, count: Int?) -> some View {
        Button {
            selection = option.value
            dismiss()
        } label: {
            HStack {
                Text(option.text).foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text(count.short)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if selection == option.value {
                    Image(systemName: "checkmark").foregroundStyle(theme.primary)
                }
            }
            .contentShape(.rect)
        }
        .themedRows()
    }
}

/// Crossover wählen: keine, alle des Fandoms oder die mit einem zweiten Fandom (meiste zuerst).
struct FFNCrossoverPicker: View {
    let home: FFNCrossRef
    let allowsNone: Bool
    @Binding var selection: FFNCrossChoice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var store = FFNCrossoverStore.shared
    @State private var search = ""

    var body: some View {
        let listing = store.listings[home.id]
        let q = search.trimmed
        List {
            if q.isEmpty {
                Section {
                    if allowsNone {
                        row(String(localized: "Keine Crossover"), count: nil, choice: .none)
                    }
                    row(String(localized: "Alle Crossover"), count: nil, choice: .all)
                }
                .themedRows()
            }
            Section {
                if let listing {
                    let partners = q.isEmpty ? listing.partners : listing.partners.filter { $0.name.localizedCaseInsensitiveContains(q) }
                    ForEach(partners) { partner in
                        row(partner.name, count: partner.count, choice: .with(partner))
                    }
                } else if store.failed.contains(home.id) {
                    Button("Liste der Fandoms konnte nicht geladen werden. Nochmal versuchen") {
                        Task { await store.load(home, force: true) }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Lade Fandoms …").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Mit einem zweiten Fandom")
            } footer: {
                if let listing, !listing.exact {
                    Text("FanFiction.net liefert für dieses Fandom keine Crossover-Liste. Hier stehen alle Fandoms mit Crossovern – nicht jedes hat gemeinsame Geschichten.")
                }
            }
            .themedRows()
        }
        .themedBackground()
        .navigationTitle("Crossover")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Fandom suchen")
        .task { await store.load(home) }
    }

    private func row(_ title: String, count: Int?, choice: FFNCrossChoice) -> some View {
        Button {
            selection = choice
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text(count.short)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if selection == choice {
                    Image(systemName: "checkmark").foregroundStyle(theme.primary)
                }
            }
            .contentShape(.rect)
        }
    }
}
