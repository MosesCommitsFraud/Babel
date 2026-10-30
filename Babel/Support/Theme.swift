import SwiftUI

/// Eine Hälfte (hell oder dunkel) einer Palette.
struct PaletteHalf: Sendable, Codable, Equatable {
    let screen: UInt32
    let card: UInt32
    let groupedCard: UInt32
    let foreground: UInt32
    let secondaryText: UInt32
    let border: UInt32
    let primary: UInt32
    let primaryForeground: UInt32
    let primaryText: UInt32
    let secondary: UInt32

    /// Kurzform: Karte = gruppierte Karte, Akzenttext = Akzent.
    init(screen: UInt32, card: UInt32, foreground: UInt32, secondaryText: UInt32, border: UInt32,
         primary: UInt32, primaryForeground: UInt32, primaryText: UInt32? = nil) {
        self.screen = screen
        self.card = card
        self.groupedCard = card
        self.foreground = foreground
        self.secondaryText = secondaryText
        self.border = border
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.primaryText = primaryText ?? primary
        self.secondary = card
    }
}

// MARK: - Eigene Farbschemata

/// Die vier Farben, die man in einem eigenen Schema wählt – der Rest wird daraus abgeleitet.
struct CustomHalf: Codable, Equatable, Sendable {
    var screen: UInt32
    var card: UInt32
    var foreground: UInt32
    var primary: UInt32

    init(screen: UInt32, card: UInt32, foreground: UInt32, primary: UInt32) {
        self.screen = screen
        self.card = card
        self.foreground = foreground
        self.primary = primary
    }

    init(_ half: PaletteHalf) {
        self.init(screen: half.screen, card: half.groupedCard, foreground: half.foreground, primary: half.primary)
    }

    /// Volle Palette: Nebentext, Linien und Text auf dem Akzent werden passend berechnet.
    var half: PaletteHalf {
        let onPrimary: UInt32 = HexColor.luminance(primary) > 0.45 ? HexColor.mix(primary, 0x000000, 0.82) : 0xFFFFFF
        // Akzent als Textfarbe muss auf dem Hintergrund lesbar bleiben – sonst Richtung Text verschieben.
        var accentText = primary
        var t = 0.0
        while HexColor.contrast(accentText, screen) < 3, t < 1 {
            t += 0.1
            accentText = HexColor.mix(primary, foreground, t)
        }
        return PaletteHalf(screen: screen, card: card, foreground: foreground,
                           secondaryText: HexColor.mix(foreground, screen, 0.42),
                           border: HexColor.mix(card, foreground, 0.1),
                           primary: primary, primaryForeground: onPrimary, primaryText: accentText)
    }

    /// Ein dunkles Gegenstück zu einer hellen Hälfte (getönt mit dem Akzent).
    var derivedDark: CustomHalf {
        CustomHalf(screen: HexColor.mix(primary, 0x0F0F10, 0.9),
                   card: HexColor.mix(primary, 0x1C1C1E, 0.86),
                   foreground: HexColor.mix(screen, 0xFFFFFF, 0.2),
                   primary: HexColor.luminance(primary) < 0.35 ? HexColor.mix(primary, 0xFFFFFF, 0.35) : primary)
    }
}

/// Ein selbst erstelltes Farbschema mit Namen, hell und dunkel.
struct CustomPalette: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var light: CustomHalf
    var dark: CustomHalf

    var key: String { "custom.\(id.uuidString)" }

    init(name: String, from palette: PaletteID) {
        self.name = name
        self.light = CustomHalf(palette.light)
        self.dark = CustomHalf(palette.dark)
    }
}

/// Rechnen mit 0xRRGGBB-Farben.
enum HexColor {
    static func components(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
    }

    static func make(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return c(r) << 16 | c(g) << 8 | c(b)
    }

    /// `t` = 0 → a, 1 → b.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let x = components(a), y = components(b)
        return make(x.0 + (y.0 - x.0) * t, x.1 + (y.1 - x.1) * t, x.2 + (y.2 - x.2) * t)
    }

    /// Relative Helligkeit nach WCAG.
    static func luminance(_ hex: UInt32) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = components(hex)
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Eintrag in der Theme-Auswahl: eingebaut oder selbst erstellt.
struct ThemeOption: Identifiable {
    let id: String
    let label: String
    let tagline: String
    let light: PaletteHalf
    let dark: PaletteHalf
    var custom: CustomPalette?
}

/// Alle wählbaren Themes; eigene liegen als JSON in den UserDefaults.
enum ThemeCatalog {
    static let customKey = "theme.custom"

    static func customs(_ json: String) -> [CustomPalette] {
        (try? JSONDecoder().decode([CustomPalette].self, from: Data(json.utf8))) ?? []
    }

    static func encode(_ palettes: [CustomPalette]) -> String {
        (try? JSONEncoder().encode(palettes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func builtIn(_ p: PaletteID) -> ThemeOption {
        ThemeOption(id: p.rawValue, label: p.label, tagline: p.tagline, light: p.light, dark: p.dark)
    }

    static func custom(_ c: CustomPalette) -> ThemeOption {
        ThemeOption(id: c.key, label: c.name, tagline: String(localized: "Eigenes Farbschema"),
                    light: c.light.half, dark: c.dark.half, custom: c)
    }

    static func options(customs: [CustomPalette]) -> [ThemeOption] {
        PaletteID.allCases.map(builtIn) + customs.map(custom)
    }

    /// Unbekannte oder gelöschte Schlüssel fallen auf das Standard-Theme zurück.
    static func option(_ key: String, customs: [CustomPalette]) -> ThemeOption {
        if let p = PaletteID(rawValue: key) { return builtIn(p) }
        if let c = customs.first(where: { $0.key == key }) { return custom(c) }
        return builtIn(AppTheme.defaultLight)
    }
}

/// Babels eigene Paletten – ruhige, entsättigte Töne, jeweils hell und dunkel aufeinander abgestimmt.
enum PaletteID: String, CaseIterable, Identifiable, Sendable {
    case hexagon, parchment, mist, lavender, rose, ink
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hexagon: String(localized: "Hexagon")
        case .parchment: String(localized: "Pergament")
        case .mist: String(localized: "Nebel")
        case .lavender: String(localized: "Lavendel")
        case .rose: String(localized: "Rosé")
        case .ink: String(localized: "Tinte")
        }
    }

    var tagline: String {
        switch self {
        case .hexagon: String(localized: "Salbeigrün wie die Galerien der Bibliothek von Babel")
        case .parchment: String(localized: "Warmes Papier und Sepia, wie alte Bücher")
        case .mist: String(localized: "Kühles Graublau für lange Nächte")
        case .lavender: String(localized: "Sanftes Violett, leicht verträumt")
        case .rose: String(localized: "Gedecktes Altrosa")
        case .ink: String(localized: "Schwarz auf Weiß, ganz ohne Farbe")
        }
    }

    var light: PaletteHalf {
        switch self {
        case .hexagon: .init(screen: 0xF4F6F1, card: 0xE9EDE4, foreground: 0x22271F, secondaryText: 0x6A7065, border: 0xD9DED2, primary: 0x5B8768, primaryForeground: 0xFFFFFF)
        case .parchment: .init(screen: 0xF7F3EA, card: 0xEEE7D8, foreground: 0x2E2820, secondaryText: 0x796E5E, border: 0xE1D7C4, primary: 0x9C7248, primaryForeground: 0xFFFFFF)
        case .mist: .init(screen: 0xF4F6F8, card: 0xE8EDF2, foreground: 0x1F2630, secondaryText: 0x66707C, border: 0xD8DEE6, primary: 0x58779A, primaryForeground: 0xFFFFFF)
        case .lavender: .init(screen: 0xF6F5F9, card: 0xEBE8F2, foreground: 0x26232F, secondaryText: 0x6E6A7C, border: 0xDDD9E8, primary: 0x7A6B9E, primaryForeground: 0xFFFFFF)
        case .rose: .init(screen: 0xF9F4F3, card: 0xF0E6E4, foreground: 0x2E2423, secondaryText: 0x7C6B69, border: 0xE5D6D3, primary: 0xA56C68, primaryForeground: 0xFFFFFF)
        case .ink: .init(screen: 0xF7F7F6, card: 0xECECEA, foreground: 0x1C1C1E, secondaryText: 0x6C6C70, border: 0xDBDBD9, primary: 0x3A3A3C, primaryForeground: 0xFFFFFF)
        }
    }

    var dark: PaletteHalf {
        switch self {
        case .hexagon: .init(screen: 0x151915, card: 0x1F241F, foreground: 0xE7ECE5, secondaryText: 0x99A297, border: 0x2C332C, primary: 0x8BBE96, primaryForeground: 0x132016)
        case .parchment: .init(screen: 0x1B1815, card: 0x26221D, foreground: 0xEDE6DA, secondaryText: 0xA69A88, border: 0x36302A, primary: 0xD0A775, primaryForeground: 0x231C14)
        case .mist: .init(screen: 0x13171C, card: 0x1D232A, foreground: 0xE6EBF0, secondaryText: 0x96A1AD, border: 0x2A323B, primary: 0x8EAFCF, primaryForeground: 0x121A22)
        case .lavender: .init(screen: 0x16141B, card: 0x211E28, foreground: 0xEAE7F0, secondaryText: 0xA19CAE, border: 0x2F2B38, primary: 0xB2A4D5, primaryForeground: 0x1B1724)
        case .rose: .init(screen: 0x1A1514, card: 0x251E1D, foreground: 0xEFE5E3, secondaryText: 0xAA9A97, border: 0x352B2A, primary: 0xD39C96, primaryForeground: 0x241817)
        case .ink: .init(screen: 0x0E0E0F, card: 0x1A1A1C, foreground: 0xEDEDEF, secondaryText: 0x98989D, border: 0x2A2A2D, primary: 0xD6D6D8, primaryForeground: 0x161617)
        }
    }
}

/// Die aktive App-Palette: Farben passen sich automatisch an hell/dunkel an.
struct AppTheme {
    var light: PaletteHalf
    var dark: PaletteHalf

    static let lightKey = "theme.light"
    static let darkKey = "theme.dark"
    /// Passend zum App-Icon.
    static let defaultLight = PaletteID.hexagon
    static let defaultDark = PaletteID.hexagon

    private func color(_ pick: (PaletteHalf) -> UInt32) -> Color {
        let l = pick(light), d = pick(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: d) : UIColor(hex: l) })
    }

    var screen: Color { color(\.screen) }
    var card: Color { color(\.groupedCard) }
    var foreground: Color { color(\.foreground) }
    var secondaryText: Color { color(\.secondaryText) }
    var border: Color { color(\.border) }
    var primary: Color { color(\.primary) }
    var primaryForeground: Color { color(\.primaryForeground) }
    var primaryText: Color { color(\.primaryText) }
    var secondary: Color { color(\.secondary) }

    /// Gedämpfte Zustandsfarben (z. B. Filter „muss“ / „ausschließen“).
    var include: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x8CC79A) : UIColor(hex: 0x4E8A5C) }) }
    var exclude: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xE08C86) : UIColor(hex: 0xB0554F) }) }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme(light: AppTheme.defaultLight.light, dark: AppTheme.defaultDark.dark)
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

/// System / immer hell / immer dunkel.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "theme.mode"
    var id: String { rawValue }

    var label: String {
        switch self { case .system: String(localized: "System"); case .light: String(localized: "Hell"); case .dark: String(localized: "Dunkel") }
    }

    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// Setzt Palette, Akzentfarbe und Hell/Dunkel für die ganze App.
struct ThemeRoot: ViewModifier {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.defaultLight.rawValue
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.defaultDark.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @AppStorage(ThemeCatalog.customKey) private var customJSON = "[]"

    func body(content: Content) -> some View {
        let customs = ThemeCatalog.customs(customJSON)
        let theme = AppTheme(light: ThemeCatalog.option(light, customs: customs).light,
                             dark: ThemeCatalog.option(dark, customs: customs).dark)
        content
            .environment(\.theme, theme)
            .tint(theme.primary)
            .preferredColorScheme(AppearanceMode(rawValue: mode)?.colorScheme)
    }
}

/// Hintergrund in Palettenfarbe für Listen und Formulare.
struct ThemedBackground: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.screen.ignoresSafeArea())
    }
}

/// Zeilenhintergrund: `grouped` für Formulare (Karte), sonst durchsichtig auf dem Bildschirmhintergrund.
struct ThemedRows: ViewModifier {
    @Environment(\.theme) private var theme
    var grouped: Bool
    func body(content: Content) -> some View {
        content.listRowBackground(grouped ? theme.card : Color.clear)
    }
}

extension View {
    func themeRoot() -> some View { modifier(ThemeRoot()) }
    func themedBackground() -> some View { modifier(ThemedBackground()) }
    func themedRows(grouped: Bool = true) -> some View { modifier(ThemedRows(grouped: grouped)) }
}

