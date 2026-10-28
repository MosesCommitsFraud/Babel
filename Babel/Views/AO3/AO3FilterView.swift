import SwiftUI

/// Gespeicherte Filter-Konfiguration für AO3.
struct SavedAO3Search: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var filters: AO3Filters
}

/// Liest und schreibt die gespeicherten AO3-Filter (UserDefaults, JSON).
enum AO3Presets {
    static let key = "ao3.savedSearches"

    static func decode(_ data: Data) -> [SavedAO3Search] {
        (try? JSONDecoder().decode([SavedAO3Search].self, from: data)) ?? []
    }

    static func encode(_ list: [SavedAO3Search]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }

    /// Gleicher Name ersetzt den alten Eintrag.
    static func saving(_ name: String, _ filters: AO3Filters, into data: Data) -> Data {
        var list = decode(data)
        list.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        list.insert(SavedAO3Search(name: name, filters: filters), at: 0)
        return encode(list)
    }
}

/// Alle Filter-Abschnitte – genutzt von der Filterwand (AO3-Tab) und vom Filter-Sheet.
struct AO3FilterSections: View {
    @Binding var draft: AO3Filters

    var body: some View {
        Group {
            Section("Suche") {
                TextField("Freitext", text: $draft.query)
                TextField("Titel", text: $draft.title)
                TextField("Autor:in", text: $draft.author)
                    .textInputAutocapitalization(.never)
            }

            Section {
                TagTokenField(title: String(localized: "Fandoms"), kind: .fandom, tags: $draft.fandoms)
                TagTokenField(title: String(localized: "Beziehungen"), kind: .relationship, tags: $draft.relationships)
                TagTokenField(title: String(localized: "Charaktere"), kind: .character, tags: $draft.characters)
                TagTokenField(title: String(localized: "Weitere Tags"), kind: .freeform, tags: $draft.freeforms)
            } header: {
                Text("Muss enthalten")
            } footer: {
                Text("Tippe, um Vorschläge von AO3 zu bekommen. Mehrere Tags müssen alle zutreffen.")
            }

            Section("Ausschließen") {
                TagTokenField(title: String(localized: "Tags ausschließen"), kind: .tag, tags: $draft.excludedTags)
            }

            Section {
                ForEach(AO3Service.ratings) { r in TriStateRow(title: r.name, state: binding(\.ratings, r.id)) }
            } header: {
                Text("Rating")
            } footer: {
                TriStateLegend()
            }

            Section("Archiv-Warnungen") {
                ForEach(AO3Service.warnings) { w in TriStateRow(title: w.name, state: binding(\.warnings, w.id)) }
            }

            Section("Kategorien") {
                ForEach(AO3Service.categories) { c in TriStateRow(title: c.name, state: binding(\.categories, c.id)) }
            }

            Section("Weitere Filter") {
                // Auswahl als eigene Seite statt Menü: Menüs in langen Formularen springen beim Öffnen weg.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Status")
                    GlassSegmented(options: AO3Completion.allCases.map { ($0, $0.label) }, selection: $draft.completion)
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Crossover")
                    GlassSegmented(options: AO3Crossover.allCases.map { ($0, $0.label) }, selection: $draft.crossover)
                }
                .padding(.vertical, 4)
                Toggle("Nur Oneshots (ein Kapitel)", isOn: $draft.singleChapter)
                Picker("Sprache", selection: $draft.language) {
                    ForEach(AO3Service.languages) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.navigationLink)
                Picker("Aktualisiert", selection: $draft.updatedWithin) {
                    ForEach(AO3UpdatedWithin.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.navigationLink)
                HStack {
                    Text("Wörter")
                    Spacer()
                    TextField("von", text: $draft.wordsFrom).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                    Text("–")
                    TextField("bis", text: $draft.wordsTo).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                }
                HStack {
                    Text("Mindestens Kudos")
                    Spacer()
                    TextField("0", text: $draft.minKudos).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                }
            }

            Section("Sortierung") {
                Picker("Sortieren nach", selection: $draft.sort) {
                    ForEach(AO3Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.navigationLink)
                Toggle("Aufsteigend", isOn: $draft.ascending)
            }
        }
        .themedRows()
    }

    private func binding(_ keyPath: WritableKeyPath<AO3Filters, [Int: TriState]>, _ id: Int) -> Binding<TriState> {
        Binding(
            get: { draft[keyPath: keyPath][id] ?? .any },
            set: { draft[keyPath: keyPath][id] = $0 == .any ? nil : $0 }
        )
    }
}

/// Filter-Sheet auf der Ergebnisseite.
struct AO3FilterView: View {
    @Binding var filters: AO3Filters
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AO3Filters
    @State private var showSave = false
    @State private var presetName = ""
    @AppStorage(AO3Presets.key) private var savedData: Data = Data()

    init(filters: Binding<AO3Filters>, onApply: @escaping () -> Void) {
        _filters = filters
        self.onApply = onApply
        // Als Startwert statt in onAppear: onAppear läuft nach jeder Auswahlseite erneut und würde Änderungen verwerfen.
        _draft = State(initialValue: filters.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                AO3FilterSections(draft: $draft)
            }
            .themedBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Filter speichern …", systemImage: "square.and.arrow.down") {
                            presetName = draft.summary
                            showSave = true
                        }
                        Button("Zurücksetzen", systemImage: "arrow.counterclockwise", role: .destructive) {
                            let query = draft.query
                            draft = AO3Filters()
                            draft.query = query
                        }
                    } label: {
                        Label("Mehr", systemImage: "ellipsis")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Suchen", systemImage: "checkmark") {
                        filters = draft
                        dismiss()
                        onApply()
                    }
                }
            }
            .alert("Filter speichern", isPresented: $showSave) {
                TextField("Name", text: $presetName)
                Button("Abbrechen", role: .cancel) {}
                Button("Speichern") {
                    let name = presetName.trimmed
                    if !name.isEmpty { savedData = AO3Presets.saving(name, draft, into: savedData) }
                }
            } message: {
                Text("Findest du im AO3-Tab unter „Gespeicherte Filter“ wieder.")
            }
        }
    }
}

struct TriStateRow: View {
    let title: String
    @Binding var state: TriState

    var body: some View {
        HStack {
            Text(title).font(.subheadline).lineLimit(2)
            Spacer()
            TriStateControl(state: $state)
        }
    }
}

struct TriStateLegend: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Label("egal", systemImage: "circle.dashed")
            Label("muss", systemImage: "checkmark").foregroundStyle(theme.include)
            Label("ausschließen", systemImage: "xmark").foregroundStyle(theme.exclude)
        }
        .font(.caption)
    }
}

/// Tag-Eingabe mit AO3-Autovervollständigung.
struct TagTokenField: View {
    let title: String
    let kind: AO3Service.TagKind
    @Binding var tags: [String]
    @Environment(\.theme) private var theme

    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var isLooking = false
    @State private var isSlow = false
    @State private var lookup: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 4) {
                                Text(tag).lineLimit(1)
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderless)
                        .glassEffect(.regular.tint(theme.primary.opacity(0.25)).interactive(), in: .capsule)
                    }
                }
            }
            HStack {
                TextField(title, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { add(text) }
                    .onChange(of: text) { _, new in fetchSuggestions(new) }
                if isLooking { ProgressView().controlSize(.small) }
            }

            if isSlow && suggestions.isEmpty {
                Text("AO3 antwortet gerade langsam. Du kannst den Tag auch ganz eintippen und mit ↵ übernehmen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !suggestions.isEmpty {
                GlassEffectContainer(spacing: 6) {
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions.prefix(8), id: \.self) { s in
                            Button { add(s) } label: {
                                Label(s, systemImage: "plus").font(.subheadline).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                            .buttonStyle(.borderless)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func add(_ value: String) {
        let v = value.trimmed
        guard !v.isEmpty, !tags.contains(v) else { return }
        tags.append(v)
        text = ""
        suggestions = []
        lookup?.cancel()
        isLooking = false
        isSlow = false
    }

    private func fetchSuggestions(_ term: String) {
        lookup?.cancel()
        guard term.trimmed.count >= 2 else { suggestions = []; isLooking = false; isSlow = false; return }
        // Sofort zeigen, was schon da ist (auch aus einem kürzeren Begriff), dann AO3 fragen.
        if let cached = AO3Service.cachedSuggestions(kind, term: term) { suggestions = cached }
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isLooking = true
            let slowHint = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { isSlow = true } }
            let result = (try? await AO3Service.autocomplete(kind, term: term)) ?? []
            slowHint.cancel()
            guard !Task.isCancelled else { return }
            isLooking = false
            isSlow = false
            if !result.isEmpty || suggestions.isEmpty { suggestions = result }
        }
    }
}
