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
/// Wer mag, mischt unten unter „Hell und Dunkel einzeln“ zwei Themes.
struct ThemeSettingsView: View {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @Environment(\.theme) private var theme
    @State private var showMixer = false
    @Namespace private var glass

    private var lightID: PaletteID { PaletteID(rawValue: light) ?? AppTheme.defaultLight }
    private var darkID: PaletteID { PaletteID(rawValue: dark) ?? AppTheme.defaultDark }
    private var isMixed: Bool { lightID != darkID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.allCases) { m in modeButton(m) }
                    }
                }

                VStack(spacing: 12) {
                    ForEach(PaletteID.allCases) { p in themeCard(p) }
                }

                DisclosureGroup(isExpanded: $showMixer) {
                    VStack(alignment: .leading, spacing: 14) {
                        mixRow(String(localized: "Hell"), "sun.max.fill", selection: $light, half: \.light)
                        mixRow(String(localized: "Dunkel"), "moon.fill", selection: $dark, half: \.dark)
                    }
                    .padding(.top, 10)
                } label: {
                    Label(isMixed ? "Gemischt: \(lightID.label) & \(darkID.label)" : "Hell und Dunkel einzeln wählen",
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

    private func themeCard(_ p: PaletteID) -> some View {
        let selected = !isMixed && lightID == p
        return Button {
            withAnimation(.bouncy(duration: 0.35)) {
                light = p.rawValue
                dark = p.rawValue
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 14) {
                HStack(spacing: -14) {
                    AppWireframe(light: p.light)
                        .frame(width: 58, height: 84)
                        .rotationEffect(.degrees(-4))
                    AppWireframe(light: p.dark)
                        .frame(width: 58, height: 84)
                        .rotationEffect(.degrees(4))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.label).font(.headline)
                    Text(p.tagline).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        swatch(p.light.primary)
                        swatch(p.light.card)
                        swatch(p.dark.primary)
                        swatch(p.dark.screen)
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
    }

    private func swatch(_ hex: UInt32) -> some View {
        Circle()
            .fill(Color(uiColor: UIColor(hex: hex)))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }

    private func mixRow(_ title: String, _ symbol: String, selection: Binding<String>, half: KeyPath<PaletteID, PaletteHalf>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PaletteID.allCases) { p in
                        let isOn = selection.wrappedValue == p.rawValue
                        Button {
                            withAnimation(.bouncy(duration: 0.3)) { selection.wrappedValue = p.rawValue }
                        } label: {
                            VStack(spacing: 5) {
                                AppWireframe(light: p[keyPath: half])
                                    .frame(width: 46, height: 64)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(isOn ? theme.primary : .clear, lineWidth: 2.5)
                                    }
                                Text(p.label).font(.caption2.weight(isOn ? .semibold : .regular))
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
                    Text(l == d ? l.label : "\(l.label) & \(d.label)").font(.subheadline).foregroundStyle(.secondary)
                    Text("Modus: \(AppearanceMode(rawValue: mode)?.label ?? "System")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
