import SwiftUI

/// Filter für die ganze Bibliothek – über AO3, FFN und Bücher hinweg.
struct LibraryQuery: Equatable, Codable {
    var fandoms: Set<String> = []
    var pairings: Set<String> = []
    var characters: Set<String> = []
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
        [!fandoms.isEmpty, !pairings.isEmpty, !characters.isEmpty, !ratings.isEmpty, completion != .any, length != .any, !languages.isEmpty, !sources.isEmpty]
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
        if !pairings.isEmpty && !s.relationships.contains(where: pairings.contains) { return false }
        if !characters.isEmpty && !s.characters.contains(where: characters.contains) { return false }
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

    /// Werte mit Anzahl, häufigste zuerst.
    private func counted(_ values: (Story) -> [String]) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for s in stories { for v in Set(values(s)) where !v.isEmpty { counts[v, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    private var ratings: [(value: String, count: Int)] {
        let found = counted { $0.rating.components(separatedBy: ", ").compactMap(LibraryQuery.ratingGroup) }
        return LibraryQuery.ratingOrder.compactMap { r in found.first { $0.value == r } }
    }

    private var sources: [(value: String, count: Int)] {
        counted { [$0.source.rawValue] }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Kompakt wie die FFN-Filter: eine Zeile pro Filter, Auswahl auf eigener Seite.
                Section {
                    multiRow("Quelle", items: sources, label: { StorySource(rawValue: $0)?.shortLabel ?? $0 },
                             selection: Binding(get: { Set(query.sources.map(\.rawValue)) },
                                                set: { query.sources = Set($0.compactMap(StorySource.init(rawValue:))) }))
                    multiRow("Rating", items: ratings, selection: $query.ratings, sorted: false)
                    Picker("Status", selection: $query.completion) {
                        ForEach(LibraryQuery.Completion.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Länge", selection: $query.length) {
                        ForEach(LibraryQuery.Length.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    multiRow("Sprache", items: counted { [$0.language] }, selection: $query.languages)
                } footer: {
                    Text("Gilt für AO3, FanFiction.net und Bücher gemeinsam.")
                }
                .themedRows()

                Section {
                    multiRow("Fandoms", items: counted(\.fandoms), selection: $query.fandoms)
                    multiRow("Pairings", items: counted(\.relationships), selection: $query.pairings)
                    multiRow("Charaktere", items: counted(\.characters), selection: $query.characters)
                } footer: {
                    Text("Bei mehreren Einträgen reicht einer davon.")
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

    private func multiRow(_ title: LocalizedStringKey, items: [(value: String, count: Int)], label: @escaping (String) -> String = { $0 },
                          selection: Binding<Set<String>>, sorted: Bool = true) -> some View {
        NavigationLink {
            MultiSelectList(title: title, items: items, label: label, selection: selection)
        } label: {
            LabeledContent(title) {
                Text(summary(selection.wrappedValue, label: label)).lineLimit(1)
            }
        }
        .disabled(items.isEmpty)
    }

    private func summary(_ set: Set<String>, label: (String) -> String) -> String {
        switch set.count {
        case 0: String(localized: "Alle")
        case 1: label(set.first!)
        default: String(localized: "\(set.count) gewählt")
        }
    }
}

/// Mehrfachauswahl mit Anzahl, meiste zuerst, durchsuchbar.
struct MultiSelectList: View {
    let title: LocalizedStringKey
    let items: [(value: String, count: Int)]
    let label: (String) -> String
    @Binding var selection: Set<String>
    @Environment(\.theme) private var theme
    @State private var search = ""

    private var visible: [(value: String, count: Int)] {
        let q = search.trimmed.lowercased()
        return q.isEmpty ? items : items.filter { label($0.value).lowercased().contains(q) }
    }

    var body: some View {
        List {
            Button {
                selection = []
            } label: {
                HStack {
                    Text("Alle").foregroundStyle(.primary)
                    Spacer()
                    if selection.isEmpty { Image(systemName: "checkmark").foregroundStyle(theme.primary) }
                }
            }
            .themedRows()
            ForEach(visible, id: \.value) { item in
                Button {
                    if selection.contains(item.value) { selection.remove(item.value) } else { selection.insert(item.value) }
                } label: {
                    HStack {
                        Text(label(item.value)).foregroundStyle(.primary).lineLimit(2)
                        Spacer()
                        Text("\(item.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: selection.contains(item.value) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(item.value) ? theme.primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .themedRows()
            }
        }
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: items.count > 12 ? .always : .automatic))
    }
}
