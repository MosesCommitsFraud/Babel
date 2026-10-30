import SwiftUI

/// Zählungen „Geschichten pro Sprache/Charakter“ je Fandom, 7 Tage im Cache.
@MainActor
@Observable
final class FFNCountStore {
    static let shared = FFNCountStore()

    private struct Entry: Codable {
        var date: Date
        var counts: [String: Int]
    }

    private var entries: [String: Entry] = [:]
    private(set) var progress: [String: (done: Int, total: Int)] = [:]

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ffn-counts.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { Date().timeIntervalSince($0.value.date) < 7 * 24 * 3600 }
        }
    }

    private static func key(_ page: URL, _ param: String) -> String { "\(page.path)|\(param)" }

    func counts(page: URL, param: String) -> [String: Int] { entries[Self.key(page, param)]?.counts ?? [:] }
    func isLoading(page: URL, param: String) -> Bool { progress[Self.key(page, param)] != nil }
    func progressText(page: URL, param: String) -> String? {
        progress[Self.key(page, param)].map { "\($0.done)/\($0.total)" }
    }

    /// Zählt alle noch fehlenden Werte, in Paketen – die Liste sortiert sich dabei schon um.
    func load(page: URL, param: String, values: [String]) async {
        let key = Self.key(page, param)
        guard progress[key] == nil else { return }
        let missing = values.filter { $0 != "0" && entries[key]?.counts[$0] == nil }
        guard !missing.isEmpty else { return }
        progress[key] = (0, missing.count)
        defer { progress[key] = nil; save() }
        var entry = entries[key] ?? Entry(date: Date(), counts: [:])
        for (i, chunk) in stride(from: 0, to: missing.count, by: 40).map({ Array(missing[$0..<min($0 + 40, missing.count)]) }).enumerated() {
            guard let result = try? await FFNService.storyCounts(pageURL: page, param: param, values: chunk) else { break }
            entry.counts.merge(result) { _, new in new }
            entry.date = Date()
            entries[key] = entry
            progress[key] = (min((i + 1) * 40, missing.count), missing.count)
        }
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: Self.file, options: .atomic)
    }
}

/// FFN-Filter wie auf der Website, übersichtlich gruppiert.
/// Charaktere sind in zwei Paaren angeordnet, jedes mit eigenem „Als Paar“-Schalter.
struct FFNFilterSheet: View {
    let filters: [FFNFilterSelect]
    let pageURL: URL
    var onApply: ([String: String], [Bool]) -> Void
    var onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    @State private var pairs: [Bool]

    init(filters: [FFNFilterSelect], pageURL: URL, pairs: [Bool],
         onApply: @escaping ([String: String], [Bool]) -> Void, onReset: @escaping () -> Void) {
        self.filters = filters
        self.pageURL = pageURL
        self.onApply = onApply
        self.onReset = onReset
        // Nicht in onAppear: das läuft nach jeder Auswahlseite erneut und würde die Auswahl zurücksetzen.
        _values = State(initialValue: Dictionary(filters.map { ($0.name, $0.selected) }, uniquingKeysWith: { a, _ in a }))
        let pm = filters.first { $0.name == "pm" }?.selected == "1"
        _pairs = State(initialValue: pairs.contains(true) ? pairs : [pm, false])
    }

    private static let sortNames = ["sortid", "timerange", "timeid"]
    private static let pairNames = [["characterid1", "characterid2"], ["characterid3", "characterid4"]]

    private func filter(_ name: String) -> FFNFilterSelect? { filters.first { $0.name == name } }

    private var contentFilters: [FFNFilterSelect] {
        let used = Set(Self.sortNames + Self.pairNames.flatMap { $0 } + ["pm", "_pm"])
        return filters.filter { !$0.isExclusion && !used.contains($0.name) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sortierung") {
                    ForEach(Self.sortNames.compactMap(filter)) { row($0) }
                }
                .themedRows()

                Section("Inhalt") {
                    ForEach(contentFilters) { row($0) }
                }
                .themedRows()

                ForEach(Array(Self.pairNames.enumerated()), id: \.offset) { index, names in
                    let selects = names.compactMap(filter)
                    if !selects.isEmpty {
                        Section {
                            ForEach(selects) { row($0) }
                            if filter("pm") != nil {
                                Toggle("Als Paar", isOn: Binding(get: { pairs[index] }, set: { pairs[index] = $0 }))
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

                let exclusions = filters.filter(\.isExclusion)
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
                        // FFN hat nur ein Pairing-Häkchen; welches Paar gemeint ist, filtert die App danach selbst.
                        if filter("pm") != nil { result["pm"] = pairs.contains(true) ? "1" : "0" }
                        dismiss()
                        onApply(result, pairs)
                    }
                }
            }
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
        } else if let param = FFNService.countParams[filter.name] {
            NavigationLink {
                FFNCountedPicker(filter: filter, title: label(filter), selection: binding, pageURL: pageURL, param: param)
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
struct FFNCountedPicker: View {
    let filter: FFNFilterSelect
    let title: String
    @Binding var selection: String
    let pageURL: URL
    let param: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var store = FFNCountStore.shared
    @State private var search = ""

    private var counts: [String: Int] { store.counts(page: pageURL, param: param) }

    private var options: [FFNOption] {
        let all = filter.options.dropFirst()
        let q = search.trimmed.lowercased()
        let filtered = q.isEmpty ? Array(all) : all.filter { $0.text.lowercased().contains(q) }
        let c = counts
        return filtered.sorted { a, b in
            let ca = c[a.value] ?? -1, cb = c[b.value] ?? -1
            return ca != cb ? ca > cb : a.text.localizedStandardCompare(b.text) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if let first = filter.options.first {
                optionRow(FFNOption(value: first.value, text: String(localized: "Alle")), count: nil)
            }
            if let progress = store.progressText(page: pageURL, param: param) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Zähle Geschichten … \(progress)").font(.footnote).foregroundStyle(.secondary)
                }
                .themedRows()
            }
            ForEach(options) { option in
                optionRow(option, count: counts[option.value])
            }
        }
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: filter.options.count > 15 ? .always : .automatic))
        .task {
            await store.load(page: pageURL, param: param, values: filter.options.map(\.value))
        }
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
                    Text(count.formatted(.number.notation(.compactName)))
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
