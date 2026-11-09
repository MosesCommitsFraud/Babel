import SwiftUI
import SwiftData

/// Angetippte oder frisch angelegte Markierung: Textstelle, Notiz, Löschen.
struct MarkSheet: View {
    let selection: ReaderModel.MarkSelection
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private var quote: String { selection.highlights.map(\.text).joined(separator: " ") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(quote).font(.callout).lineLimit(6)
                }
                .themedRows()
                Section("Notiz") {
                    TextField("Dein Gedanke dazu", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($noteFocused)
                }
                .themedRows()
                Section {
                    Button("Markierung löschen", systemImage: "trash", role: .destructive) {
                        model.deleteMarks(selection.highlights)
                        dismiss()
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Markierung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            note = selection.highlights.first?.note ?? ""
            // Frisch mit „Notiz“ angelegt: gleich losschreiben.
            if note.isEmpty { noteFocused = true }
        }
    }

    /// Die Notiz gehört zur ersten Teilstelle – eine Auswahl über mehrere Absätze ist für Leser:innen eine Markierung.
    private func save() {
        guard let first = selection.highlights.first, first.note != note.trimmed else { return }
        first.note = note.trimmed
        model.marksChanged()
    }
}

/// Alle Markierungen einer Geschichte, nach Kapitel. Tippen öffnet die Stelle im Reader.
struct HighlightsView: View {
    let story: Story
    var onOpen: (Highlight) -> Void
    @Environment(\.modelContext) private var context
    @Query private var highlights: [Highlight]

    init(story: Story, onOpen: @escaping (Highlight) -> Void) {
        self.story = story
        self.onOpen = onOpen
        let key = story.key
        _highlights = Query(filter: #Predicate<Highlight> { $0.storyKey == key },
                            sort: [SortDescriptor(\.chapter), SortDescriptor(\.paragraph), SortDescriptor(\.start)])
    }

    private var chapters: [(index: Int, items: [Highlight])] {
        Dictionary(grouping: highlights, by: \.chapter).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            ForEach(chapters, id: \.index) { chapter in
                Section(story.title(ofChapter: chapter.index)) {
                    ForEach(chapter.items) { highlight in
                        Button { onOpen(highlight) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(highlight.text).font(.callout).foregroundStyle(.primary).lineLimit(5)
                                if !highlight.note.isEmpty {
                                    Label(highlight.note, systemImage: "note.text")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                context.delete(highlight)
                                try? context.save()
                            }
                        }
                    }
                }
                .themedRows()
            }
        }
        .themedBackground()
        .navigationTitle("Markierungen")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if highlights.isEmpty {
                ContentUnavailableView("Noch keine Markierungen", systemImage: "highlighter",
                                       description: Text("Markiere im Reader Text und wähle „Markieren“ oder „Notiz“."))
            }
        }
    }
}

/// Zeile auf der Detailseite – nur sichtbar, wenn Markierungen eingeschaltet sind und es welche gibt.
struct HighlightsLink: View {
    let story: Story
    var onOpen: (Highlight) -> Void
    @Environment(\.theme) private var theme
    @AppStorage(HighlightSettings.key) private var enabled = false
    @Query private var highlights: [Highlight]

    init(story: Story, onOpen: @escaping (Highlight) -> Void) {
        self.story = story
        self.onOpen = onOpen
        let key = story.key
        _highlights = Query(filter: #Predicate<Highlight> { $0.storyKey == key })
    }

    var body: some View {
        if enabled, !highlights.isEmpty {
            NavigationLink {
                HighlightsView(story: story, onOpen: onOpen)
            } label: {
                HStack {
                    Label("Markierungen", systemImage: "highlighter").font(.headline)
                    Spacer()
                    Text("\(highlights.count)").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(theme.card, in: .rect(cornerRadius: 16))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}
