import SwiftUI

/// Filter für die ganze Bibliothek – über AO3, FFN und Bücher hinweg.
struct LibraryQuery: Equatable, Codable {
    var fandoms: Set<String> = []
    var ratings: Set<String> = []
    var completion: Completion = .any
    var length: Length = .any
    var languages: Set<String> = []
    var sources: Set<StorySource> = []

    enum Completion: String, CaseIterable, Codable {
        case any, complete, inProgress
        var label: String {
            switch self {
            case .any: String(localized: "Alle")
            case .complete: String(localized: "Abgeschlossen")
            case .inProgress: String(localized: "In Arbeit")
            }
        }
    }

    enum Length: String, CaseIterable, Codable {
        case any, short, medium, long, epic
        var label: String {
            switch self {
            case .any: String(localized: "Alle")
            case .short: String(localized: "< 10k")
            case .medium: String(localized: "10–50k")
            case .long: String(localized: "50–150k")
            case .epic: String(localized: "> 150k")
            }
        }
        func contains(_ words: Int?) -> Bool {
            guard let w = words else { return self == .any }
            switch self {
            case .any: return true
            case .short: return w < 10_000
            case .medium: return w >= 10_000 && w < 50_000
            case .long: return w >= 50_000 && w < 150_000
            case .epic: return w >= 150_000
            }
        }
    }

    var activeCount: Int {
        [!fandoms.isEmpty, !ratings.isEmpty, completion != .any, length != .any, !languages.isEmpty, !sources.isEmpty]
            .filter { $0 }.count
    }

    /// AO3- und FFN-Ratings auf eine gemeinsame Skala bringen.
    static func ratingGroup(_ rating: String) -> String? {
        switch rating.trimmed {
        case "General Audiences", "K", "G": "K / G"
        case "K+": "K+"
        case "Teen And Up Audiences", "T": "T"
        case "Mature", "M": "M"
        case "Explicit", "E", "MA": "E"
        case "Not Rated": String(localized: "Ohne Rating")
        default: nil
        }
    }

    static let ratingOrder = ["K / G", "K+", "T", "M", "E", String(localized: "Ohne Rating")]

    func matches(_ s: Story) -> Bool {
        if !fandoms.isEmpty && !s.fandoms.contains(where: fandoms.contains) { return false }
        if !ratings.isEmpty {
            let groups = s.rating.components(separatedBy: ", ").compactMap(Self.ratingGroup)
            if !groups.contains(where: ratings.contains) { return false }
        }
        switch completion {
        case .any: break
        case .complete: if !s.isComplete { return false }
        case .inProgress: if s.isComplete { return false }
        }
        if !length.contains(s.words) { return false }
        if !languages.isEmpty && !languages.contains(s.language) { return false }
        if !sources.isEmpty && !sources.contains(s.source) { return false }
        return true
    }
}

struct LibraryFilterSheet: View {
    @Binding var query: LibraryQuery
    let stories: [Story]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var fandomSearch = ""
    @State private var showAllFandoms = false

    /// Werte mit Anzahl, häufigste zuerst.
    private func counted(_ values: (Story) -> [String]) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for s in stories { for v in Set(values(s)) where !v.isEmpty { counts[v, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    private var fandoms: [(value: String, count: Int)] {
        let all = counted(\.fandoms)
        let q = fandomSearch.trimmed.lowercased()
        return q.isEmpty ? all : all.filter { $0.value.lowercased().contains(q) }
    }

    private var ratings: [(value: String, count: Int)] {
        let found = counted { $0.rating.components(separatedBy: ", ").compactMap(LibraryQuery.ratingGroup) }
        return LibraryQuery.ratingOrder.compactMap { r in found.first { $0.value == r } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Quelle") {
                    chipFlow(StorySource.allCases.filter { src in stories.contains { $0.source == src } }.map { ($0.shortLabel, $0) },
                             selection: $query.sources)
                }
                .themedRows()

                Section("Rating") {
                    chipFlow(ratings.map { ("\($0.value)  \($0.count)", $0.value) }, selection: $query.ratings)
                }
                .themedRows()

                Section("Status") {
                    GlassSegmented(options: LibraryQuery.Completion.allCases.map { ($0, $0.label) }, selection: $query.completion)
                        .padding(.vertical, 4)
                }
                .themedRows()

                Section("Länge (Wörter)") {
                    GlassSegmented(options: LibraryQuery.Length.allCases.map { ($0, $0.label) }, selection: $query.length)
                        .padding(.vertical, 4)
                }
                .themedRows()

                let languages = counted { [$0.language] }
                if languages.count > 1 {
                    Section("Sprache") {
                        chipFlow(languages.prefix(12).map { ("\($0.value)  \($0.count)", $0.value) }, selection: $query.languages)
                    }
                    .themedRows()
                }

                Section {
                    TextField("Fandom suchen", text: $fandomSearch)
                        .textInputAutocapitalization(.never)
                    let list = fandoms
                    ForEach(list.prefix(showAllFandoms || !fandomSearch.isEmpty ? list.count : 12), id: \.value) { f in
                        Button {
                            if query.fandoms.contains(f.value) { query.fandoms.remove(f.value) } else { query.fandoms.insert(f.value) }
                        } label: {
                            HStack {
                                Text(f.value).foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                Text("\(f.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: query.fandoms.contains(f.value) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(query.fandoms.contains(f.value) ? theme.primary : .secondary)
                            }
                        }
                    }
                    if list.count > 12 && !showAllFandoms && fandomSearch.isEmpty {
                        Button("Alle \(list.count) Fandoms zeigen") { withAnimation { showAllFandoms = true } }
                    }
                } header: {
                    Text("Fandoms")
                } footer: {
                    Text("Mehrere Fandoms: Es reicht, wenn eine Geschichte zu einem davon gehört.")
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Bibliothek filtern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") { withAnimation { query = LibraryQuery() } }
                        .disabled(query.activeCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    /// Mehrfachauswahl als Glas-Chips.
    private func chipFlow<Value: Hashable>(_ options: [(String, Value)], selection: Binding<Set<Value>>) -> some View {
        GlassEffectContainer(spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.1) { title, value in
                    GlassChip(title: title, isSelected: selection.wrappedValue.contains(value)) {
                        withAnimation(.snappy) {
                            if selection.wrappedValue.contains(value) { selection.wrappedValue.remove(value) }
                            else { selection.wrappedValue.insert(value) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
