import SwiftUI

/// Eigenes Farbschema bauen: vier Farben je für hell und dunkel, mit Live-Vorschau.
struct CustomThemeEditor: View {
    let isNew: Bool
    var onSave: (CustomPalette) -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var palette: CustomPalette
    @State private var editingDark = false
    @State private var confirmDelete = false

    init(palette: CustomPalette, isNew: Bool, onSave: @escaping (CustomPalette) -> Void, onDelete: @escaping () -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _palette = State(initialValue: palette)
    }

    /// Die gerade bearbeitete Hälfte.
    private var half: Binding<CustomHalf> {
        editingDark ? $palette.dark : $palette.light
    }

    private var preview: AppTheme { AppTheme(light: palette.light.half, dark: palette.dark.half) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    previewPair
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
                .listRowBackground(Color.clear)

                Section("Name") {
                    TextField("Name", text: $palette.name)
                }
                .themedRows()

                Section {
                    Picker("Variante", selection: $editingDark.animation(.snappy)) {
                        Label("Hell", systemImage: "sun.max.fill").tag(false)
                        Label("Dunkel", systemImage: "moon.fill").tag(true)
                    }
                    .pickerStyle(.segmented)
                    colorRow("Akzent", "Knöpfe, Auswahl, Links", \.primary)
                    colorRow("Hintergrund", "Fläche hinter allem", \.screen)
                    colorRow("Karten & Felder", "Listenzeilen, Suchfeld, Chips", \.card)
                    colorRow("Text", "Titel und Fließtext", \.foreground)
                } header: {
                    Text("Farben")
                } footer: {
                    if HexColor.contrast(half.wrappedValue.foreground, half.wrappedValue.screen) < 4.5 {
                        Label("Der Text ist auf diesem Hintergrund schwer lesbar.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Nebentext, Linien und die Schrift auf dem Akzent berechnet Babel daraus.")
                    }
                }
                .themedRows()

                Section {
                    if !editingDark {
                        Button("Dunkle Variante passend erzeugen", systemImage: "moon.stars") {
                            withAnimation(.snappy) {
                                palette.dark = palette.light.derivedDark
                                editingDark = true
                            }
                        }
                    }
                    Menu {
                        ForEach(PaletteID.allCases) { p in
                            Button(p.label) {
                                withAnimation(.snappy) {
                                    palette.light = CustomHalf(p.light)
                                    palette.dark = CustomHalf(p.dark)
                                }
                            }
                        }
                    } label: {
                        Label("Farben aus Theme übernehmen", systemImage: "square.on.square")
                    }
                } header: {
                    Text("Vorlage")
                }
                .themedRows()

                if !isNew {
                    Section {
                        Button("Farbschema löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                    .themedRows()
                }
            }
            // Der Editor zeigt sich selbst schon im neuen Schema.
            .themedBackground()
            .environment(\.theme, preview)
            .tint(preview.primary)
            .navigationTitle(isNew ? "Neues Farbschema" : "Farbschema bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", systemImage: "checkmark") {
                        palette.name = palette.name.trimmed
                        onSave(palette)
                        dismiss()
                    }
                    .disabled(palette.name.trimmed.isEmpty)
                }
            }
            .confirmationDialog("„\(palette.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
        }
        .preferredColorScheme(editingDark ? .dark : .light)
    }

    /// Hell und dunkel nebeneinander; Tippen wählt die Variante zum Bearbeiten.
    private var previewPair: some View {
        HStack(spacing: 16) {
            previewPane(dark: false)
            previewPane(dark: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func previewPane(dark: Bool) -> some View {
        let selected = editingDark == dark
        return Button {
            withAnimation(.snappy) { editingDark = dark }
        } label: {
            VStack(spacing: 6) {
                AppWireframe(light: dark ? palette.dark.half : palette.light.half)
                    .frame(width: 112, height: 168)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? preview.primary : .clear, lineWidth: 3)
                    }
                    .scaleEffect(selected ? 1 : 0.94)
                Label(dark ? "Dunkel" : "Hell", systemImage: dark ? "moon.fill" : "sun.max.fill")
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func colorRow(_ title: LocalizedStringKey, _ hint: LocalizedStringKey, _ key: WritableKeyPath<CustomHalf, UInt32>) -> some View {
        ColorPicker(selection: Binding(
            get: { Color(uiColor: UIColor(hex: half.wrappedValue[keyPath: key])) },
            set: { half.wrappedValue[keyPath: key] = $0.hexValue }
        ), supportsOpacity: false) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension Color {
    /// 0xRRGGBB im sRGB-Raum (Werte außerhalb werden gekappt).
    var hexValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return HexColor.make(Double(r), Double(g), Double(b))
    }
}
