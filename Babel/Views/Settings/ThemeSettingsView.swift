import SwiftUI

/// Mini-Vorschau der App in einer Palette (wie die Wireframes in den t3code-Einstellungen).
/// Mit `dark` wird die Fläche senkrecht geteilt: links hell, rechts dunkel.
struct AppWireframe: View {
    let light: PaletteHalf
    var dark: PaletteHalf? = nil

    var body: some View {
        ZStack {
            WireframePane(half: light)
            if let dark {
                WireframePane(half: dark)
                    .mask {
                        GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width / 2).offset(x: geo.size.width / 2)
                        }
                    }
                GeometryReader { geo in
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1).offset(x: geo.size.width / 2 - 0.5)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.3), lineWidth: 1) }
    }
}

/// Ein Bildschirm: Titel, Suchfeld, drei Listenzeilen mit Cover, Hauptknopf, Tab-Leiste.
private struct WireframePane: View {
    let half: PaletteHalf

    private func c(_ hex: UInt32, _ opacity: Double = 1) -> Color { Color(uiColor: UIColor(hex: hex)).opacity(opacity) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let line = c(half.secondaryText, 0.35)
            ZStack(alignment: .topLeading) {
                c(half.screen)
                VStack(alignment: .leading, spacing: h * 0.035) {
                    Capsule().fill(c(half.foreground)).frame(width: w * 0.42, height: h * 0.05)
                    Capsule().fill(c(half.groupedCard)).frame(height: h * 0.07)
                        .overlay(alignment: .leading) {
                            Capsule().fill(line).frame(width: w * 0.3, height: h * 0.02).padding(.leading, w * 0.05)
                        }
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: w * 0.04) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row == 0 ? c(half.primary) : c(half.secondaryText, row == 1 ? 0.45 : 0.25))
                                .frame(width: w * 0.12, height: h * 0.1)
                            VStack(alignment: .leading, spacing: h * 0.018) {
                                Capsule().fill(c(half.foreground, 0.8)).frame(width: w * (row == 1 ? 0.38 : 0.5), height: h * 0.025)
                                Capsule().fill(line).frame(width: w * 0.32, height: h * 0.02)
                            }
                        }
                    }
                    Capsule().fill(c(half.primary)).frame(height: h * 0.075)
                        .overlay { Capsule().fill(c(half.primaryForeground, 0.85)).frame(width: w * 0.22, height: h * 0.02) }
                }
                .padding(w * 0.08)
                // Tab-Leiste aus Glas
                Capsule()
                    .fill(c(half.groupedCard))
                    .overlay(Capsule().strokeBorder(c(half.border), lineWidth: 0.5))
                    .overlay {
                        HStack(spacing: w * 0.1) {
                            Circle().fill(c(half.primary)).frame(width: h * 0.04)
                            ForEach(0..<3, id: \.self) { _ in Circle().fill(line).frame(width: h * 0.04) }
                        }
                    }
                    .frame(width: w * 0.8, height: h * 0.09)
                    .position(x: w / 2, y: h * 0.92)
            }
        }
    }
}

/// Einstellungsseite „Farben“: Modus wählen und ein Theme (hell + dunkel) mit einem Tipp übernehmen.
/// Darunter eigene Farbschemata; wer mag, mischt unter „Hell und Dunkel einzeln“ zwei Themes.
struct ThemeSettingsView: View {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @AppStorage(ThemeCatalog.customKey) private var customJSON = "[]"
    @Environment(\.theme) private var theme
    @State private var showMixer = false
    @State private var editing: CustomPalette?
    @Namespace private var glass

    private var customs: [CustomPalette] { ThemeCatalog.customs(customJSON) }
    private var options: [ThemeOption] { ThemeCatalog.options(customs: customs) }
    private var lightOption: ThemeOption { ThemeCatalog.option(light, customs: customs) }
    private var darkOption: ThemeOption { ThemeCatalog.option(dark, customs: customs) }
    private var isMixed: Bool { lightOption.id != darkOption.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.allCases) { m in modeButton(m) }
                    }
                }

                VStack(spacing: 12) {
                    ForEach(PaletteID.allCases) { p in themeCard(ThemeCatalog.builtIn(p)) }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Eigene Farbschemata").font(.headline)
                    ForEach(customs) { c in themeCard(ThemeCatalog.custom(c)) }
                    Button {
                        editing = CustomPalette(name: String(localized: "Mein Theme"),
                                                from: PaletteID(rawValue: light) ?? AppTheme.defaultLight)
                    } label: {
                        Label("Farbschema erstellen", systemImage: "paintpalette")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    if customs.isEmpty {
                        Text("Akzent, Hintergrund, Karten und Text selbst wählen – für hell und dunkel. Halte ein Theme gedrückt, um es als Vorlage zu nehmen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup(isExpanded: $showMixer) {
                    VStack(alignment: .leading, spacing: 14) {
                        mixRow(String(localized: "Hell"), "sun.max.fill", selection: $light, dark: false)
                        mixRow(String(localized: "Dunkel"), "moon.fill", selection: $dark, dark: true)
                    }
                    .padding(.top, 10)
                } label: {
                    Label(isMixed ? "Gemischt: \(lightOption.label) & \(darkOption.label)" : "Hell und Dunkel einzeln wählen",
                          systemImage: "circle.lefthalf.filled")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding()
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationTitle("Farben")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if isMixed { showMixer = true } }
        .sheet(item: $editing) { palette in
            CustomThemeEditor(palette: palette,
                              isNew: !customs.contains { $0.id == palette.id },
                              onSave: save,
                              onDelete: { delete(palette) })
        }
    }

    // MARK: Eigene speichern / löschen

    private func save(_ palette: CustomPalette) {
        var list = customs
        if let i = list.firstIndex(where: { $0.id == palette.id }) { list[i] = palette } else { list.append(palette) }
        withAnimation(.bouncy(duration: 0.35)) {
            customJSON = ThemeCatalog.encode(list)
            light = palette.key
            dark = palette.key
        }
    }

    private func delete(_ palette: CustomPalette) {
        withAnimation(.snappy) {
            customJSON = ThemeCatalog.encode(customs.filter { $0.id != palette.id })
            if light == palette.key { light = AppTheme.defaultLight.rawValue }
            if dark == palette.key { dark = AppTheme.defaultDark.rawValue }
        }
    }

    // MARK: Modus

    private func modeButton(_ m: AppearanceMode) -> some View {
        let selected = mode == m.rawValue
        return Button {
            withAnimation(.bouncy(duration: 0.35)) { mode = m.rawValue }
        } label: {
            Label(m.label, systemImage: m == .system ? "circle.lefthalf.filled" : m == .light ? "sun.max.fill" : "moon.fill")
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.primaryForeground : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(theme.primary).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID("mode-\(m.rawValue)", in: glass)
    }

    // MARK: Themes

    private func themeCard(_ option: ThemeOption) -> some View {
        let selected = !isMixed && lightOption.id == option.id
        return Button {
            withAnimation(.bouncy(duration: 0.35)) {
                light = option.id
                dark = option.id
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 14) {
                HStack(spacing: -14) {
                    AppWireframe(light: option.light)
                        .frame(width: 58, height: 84)
                        .rotationEffect(.degrees(-4))
                    AppWireframe(light: option.dark)
                        .frame(width: 58, height: 84)
                        .rotationEffect(.degrees(4))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).font(.headline).lineLimit(1)
                    Text(option.tagline).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        swatch(option.light.primary)
                        swatch(option.light.card)
                        swatch(option.dark.primary)
                        swatch(option.dark.screen)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? theme.primary : Color.secondary.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(12)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(theme.primary.opacity(0.18)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 22))
        .overlay(alignment: .topTrailing) {
            if let custom = option.custom {
                Button("Bearbeiten", systemImage: "pencil") { editing = custom }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .padding(8)
            }
        }
        .contextMenu {
            if let custom = option.custom {
                Button("Bearbeiten", systemImage: "pencil") { editing = custom }
                Button("Duplizieren", systemImage: "plus.square.on.square") {
                    var copy = custom
                    copy.id = UUID()
                    copy.name = String(localized: "\(custom.name) Kopie")
                    editing = copy
                }
                Button("Löschen", systemImage: "trash", role: .destructive) { delete(custom) }
            } else {
                Button("Als Vorlage für eigenes Schema", systemImage: "paintpalette") {
                    editing = CustomPalette(name: String(localized: "\(option.label) eigen"),
                                            from: PaletteID(rawValue: option.id) ?? AppTheme.defaultLight)
                }
            }
        }
    }

    private func swatch(_ hex: UInt32) -> some View {
        Circle()
            .fill(Color(uiColor: UIColor(hex: hex)))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }

    private func mixRow(_ title: String, _ symbol: String, selection: Binding<String>, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options) { option in
                        let isOn = selection.wrappedValue == option.id
                        Button {
                            withAnimation(.bouncy(duration: 0.3)) { selection.wrappedValue = option.id }
                        } label: {
                            VStack(spacing: 5) {
                                AppWireframe(light: dark ? option.dark : option.light)
                                    .frame(width: 46, height: 64)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(isOn ? theme.primary : .clear, lineWidth: 2.5)
                                    }
                                Text(option.label).font(.caption2.weight(isOn ? .semibold : .regular))
                                    .lineLimit(1)
                                    .frame(maxWidth: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Zeile in den Einstellungen: aktuelle Kombination mit Vorschau, führt zur Farbseite.
struct ThemeSettingsRow: View {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @AppStorage(ThemeCatalog.customKey) private var customJSON = "[]"

    var body: some View {
        let customs = ThemeCatalog.customs(customJSON)
        let l = ThemeCatalog.option(light, customs: customs)
        let d = ThemeCatalog.option(dark, customs: customs)
        NavigationLink {
            ThemeSettingsView()
        } label: {
            HStack(spacing: 14) {
                AppWireframe(light: l.light, dark: d.dark)
                    .frame(width: 54, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Farben").font(.headline)
                    Text(l.id == d.id ? l.label : "\(l.label) & \(d.label)").font(.subheadline).foregroundStyle(.secondary)
                    Text("Modus: \(AppearanceMode(rawValue: mode)?.label ?? "System")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
