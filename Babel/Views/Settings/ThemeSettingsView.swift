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

/// Einstellungsseite „Farben“: Modus wählen und Paletten für hell und dunkel zuweisen.
struct ThemeSettingsView: View {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @Environment(\.theme) private var theme

    private var lightID: PaletteID { PaletteID(rawValue: light) ?? AppTheme.defaultLight }
    private var darkID: PaletteID { PaletteID(rawValue: dark) ?? AppTheme.defaultDark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Erscheinungsbild").font(.headline)
                    HStack(spacing: 12) {
                        ForEach(AppearanceMode.allCases) { m in modeTile(m) }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Paletten").font(.headline)
                        Spacer()
                        if lightID != AppTheme.defaultLight || darkID != AppTheme.defaultDark {
                            Button("Standard") {
                                withAnimation(.snappy) {
                                    light = AppTheme.defaultLight.rawValue
                                    dark = AppTheme.defaultDark.rawValue
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                    Text("Tippe auf eine Palette, um sie für Hell, Dunkel oder beides zu verwenden. Die Farben stammen aus t3code.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(PaletteID.allCases) { p in paletteCard(p) }
                    }
                }
            }
            .padding()
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationTitle("Farben")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeTile(_ m: AppearanceMode) -> some View {
        let selected = mode == m.rawValue
        return Button {
            withAnimation(.snappy) { mode = m.rawValue }
        } label: {
            VStack(spacing: 8) {
                Group {
                    switch m {
                    case .system: AppWireframe(light: lightID.light, dark: darkID.dark)
                    case .light: AppWireframe(light: lightID.light)
                    case .dark: AppWireframe(light: darkID.dark)
                    }
                }
                .aspectRatio(0.66, contentMode: .fit)
                Label(m.label, systemImage: m == .system ? "circle.lefthalf.filled" : m == .light ? "sun.max.fill" : "moon.fill")
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(8)
            .background(selected ? theme.primary.opacity(0.12) : theme.card, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? theme.primary : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private func paletteCard(_ p: PaletteID) -> some View {
        let isLight = lightID == p, isDark = darkID == p
        return Menu {
            Button("Für Hell verwenden", systemImage: "sun.max") { withAnimation(.snappy) { light = p.rawValue } }
            Button("Für Dunkel verwenden", systemImage: "moon") { withAnimation(.snappy) { dark = p.rawValue } }
            Button("Für beides verwenden", systemImage: "circle.lefthalf.filled") {
                withAnimation(.snappy) { light = p.rawValue; dark = p.rawValue }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AppWireframe(light: p.light, dark: p.dark)
                    .aspectRatio(1.1, contentMode: .fit)
                HStack(spacing: 6) {
                    Circle().fill(Color(uiColor: UIColor(hex: p.light.primary))).frame(width: 10, height: 10)
                    Circle().fill(Color(uiColor: UIColor(hex: p.dark.primary))).frame(width: 10, height: 10)
                    Text(p.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    if isLight { badge("Hell", "sun.max.fill") }
                    if isDark { badge("Dunkel", "moon.fill") }
                    if !isLight && !isDark { Text(" ").font(.caption2) }
                }
            }
            .padding(10)
            .background(theme.card, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(isLight || isDark ? theme.primary : .clear, lineWidth: 2)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(theme.primaryForeground)
            .background(theme.primary, in: .capsule)
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
