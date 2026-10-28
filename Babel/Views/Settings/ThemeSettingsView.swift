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

/// Einstellungsseite „Farben“ in Liquid Glass: Modus wählen, dann für Hell und Dunkel je eine Palette.
/// Oben wählt man, welche Hälfte man gerade einstellt; ein Tipp auf eine Palette übernimmt sie sofort.
struct ThemeSettingsView: View {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingDark = false
    @State private var didInit = false
    @Namespace private var glass

    private var lightID: PaletteID { PaletteID(rawValue: light) ?? AppTheme.defaultLight }
    private var darkID: PaletteID { PaletteID(rawValue: dark) ?? AppTheme.defaultDark }
    private var editedID: PaletteID { editingDark ? darkID : lightID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("Erscheinungsbild") {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(AppearanceMode.allCases) { m in modeButton(m) }
                        }
                    }
                }

                section("Paletten") {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            slotCard(dark: false)
                            slotCard(dark: true)
                        }
                    }
                }

                section(editingDark ? "Palette für Dunkel" : "Palette für Hell") {
                    GlassEffectContainer(spacing: 10) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(PaletteID.allCases) { p in paletteButton(p) }
                        }
                    }
                    Text("Gedrückt halten, um eine Palette für Hell und Dunkel zu nehmen. Die Farben stammen aus t3code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if lightID != AppTheme.defaultLight || darkID != AppTheme.defaultDark {
                    Button {
                        withAnimation(.bouncy) {
                            light = AppTheme.defaultLight.rawValue
                            dark = AppTheme.defaultDark.rawValue
                        }
                    } label: {
                        Label("Standard: Iris & Grove", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .padding()
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationTitle("Farben")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            editingDark = colorScheme == .dark
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
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

    // MARK: Hell / Dunkel

    private func slotCard(dark isDark: Bool) -> some View {
        let selected = editingDark == isDark
        let palette = isDark ? darkID : lightID
        return Button {
            withAnimation(.bouncy(duration: 0.35)) { editingDark = isDark }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                AppWireframe(light: isDark ? palette.dark : palette.light)
                    .aspectRatio(0.8, contentMode: .fit)
                HStack(spacing: 6) {
                    Image(systemName: isDark ? "moon.fill" : "sun.max.fill")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(isDark ? "Dunkel" : "Hell").font(.caption).foregroundStyle(.secondary)
                        Text(palette.label).font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "pencil.circle.fill").foregroundStyle(theme.primary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(10)
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(theme.primary.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 24))
        .glassEffectID(isDark ? "slot-dark" : "slot-light", in: glass)
    }

    // MARK: Paletten

    private func paletteButton(_ p: PaletteID) -> some View {
        let selected = editedID == p
        let half = editingDark ? p.dark : p.light
        return Button {
            withAnimation(.bouncy(duration: 0.35)) {
                if editingDark { dark = p.rawValue } else { light = p.rawValue }
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 6) {
                AppWireframe(light: half)
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(uiColor: UIColor(hex: half.primaryForeground)), Color(uiColor: UIColor(hex: half.primary)))
                                .padding(5)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(p.label).font(.caption.weight(selected ? .semibold : .regular))
            }
            .padding(7)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color(uiColor: UIColor(hex: half.primary)).opacity(0.45)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 20))
        .contextMenu {
            Button("Für Hell und Dunkel verwenden", systemImage: "circle.lefthalf.filled") {
                withAnimation(.bouncy) { light = p.rawValue; dark = p.rawValue }
            }
        }
    }
}

/// Zeile in den Einstellungen: aktuelle Kombination mit Vorschau, führt zur Farbseite.
struct ThemeSettingsRow: View {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue

    var body: some View {
        let l = PaletteID(rawValue: light) ?? AppTheme.defaultLight
        let d = PaletteID(rawValue: dark) ?? AppTheme.defaultDark
        NavigationLink {
            ThemeSettingsView()
        } label: {
            HStack(spacing: 14) {
                AppWireframe(light: l.light, dark: d.dark)
                    .frame(width: 54, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Farben").font(.headline)
                    Text("Hell: \(l.label) · Dunkel: \(d.label)").font(.subheadline).foregroundStyle(.secondary)
                    Text("Modus: \(AppearanceMode(rawValue: mode)?.label ?? "System")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
