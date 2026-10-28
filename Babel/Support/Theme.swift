import SwiftUI

/// Eine Hälfte (hell oder dunkel) einer Palette.
struct PaletteHalf: Sendable {
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
         primary: UInt32, primaryForeground: UInt32) {
        self.screen = screen
        self.card = card
        self.groupedCard = card
        self.foreground = foreground
        self.secondaryText = secondaryText
        self.border = border
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.primaryText = primary
        self.secondary = card
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
    var light: PaletteID
    var dark: PaletteID

    static let lightKey = "theme.light"
    static let darkKey = "theme.dark"
    /// Passend zum App-Icon.
    static let defaultLight = PaletteID.hexagon
    static let defaultDark = PaletteID.hexagon

    private func color(_ pick: (PaletteHalf) -> UInt32) -> Color {
        let l = pick(light.light), d = pick(dark.dark)
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
    static let defaultValue = AppTheme(light: AppTheme.defaultLight, dark: AppTheme.defaultDark)
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

    func body(content: Content) -> some View {
        let theme = AppTheme(light: PaletteID(rawValue: light) ?? AppTheme.defaultLight,
                             dark: PaletteID(rawValue: dark) ?? AppTheme.defaultDark)
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

