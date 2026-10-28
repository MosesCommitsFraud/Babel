import SwiftUI

/// Farbpaletten aus t3code (apps/mobile/generated-uniwind-themes.css), je eine helle und eine dunkle Hälfte.
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
}

enum PaletteID: String, CaseIterable, Identifiable, Sendable {
    case standard, t3chat, grove, ocean, ember, iris
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .t3chat: String(localized: "T3 Chat")
        case .grove: String(localized: "Grove")
        case .ocean: String(localized: "Ocean")
        case .ember: String(localized: "Ember")
        case .iris: String(localized: "Iris")
        }
    }

    var light: PaletteHalf {
        switch self {
        case .standard: .init(screen: 0xfcfcfc, card: 0xffffff, groupedCard: 0xf4f4f5, foreground: 0x27272a, secondaryText: 0x6f6f79, border: 0xe4e4e7, primary: 0x1b4ed8, primaryForeground: 0xffffff, primaryText: 0x1b4ed8, secondary: 0xfafafa)
        case .t3chat: .init(screen: 0xfdf7fd, card: 0xfaf3fb, groupedCard: 0xf3e6f5, foreground: 0x501854, secondaryText: 0xab1668, border: 0xeee1ed, primary: 0xdb2777, primaryForeground: 0xffffff, primaryText: 0xaa1e5d, secondary: 0xf1c4e6)
        case .grove: .init(screen: 0xf3f7f4, card: 0xf3f7f4, groupedCard: 0xe6f0ea, foreground: 0x241523, secondaryText: 0x6f686f, border: 0xcbd5d1, primary: 0x8f6410, primaryForeground: 0xfffaff, primaryText: 0x8d6210, secondary: 0xe2ede7)
        case .ocean: .init(screen: 0xf5f7f8, card: 0xf5f7f8, groupedCard: 0xe8eff4, foreground: 0x241523, secondaryText: 0x706870, border: 0xcdd4dc, primary: 0x0a6f75, primaryForeground: 0xfffaff, primaryText: 0x0a6f75, secondary: 0xe4ecf2)
        case .ember: .init(screen: 0xf9f7f5, card: 0xf9f7f5, groupedCard: 0xf4ede9, foreground: 0x241523, secondaryText: 0x726870, border: 0xddd2ce, primary: 0xb23535, primaryForeground: 0xfffaff, primaryText: 0xb23535, secondary: 0xf3eae5)
        case .iris: .init(screen: 0xf8f7f9, card: 0xf8f7f9, groupedCard: 0xf0edf6, foreground: 0x241523, secondaryText: 0x716871, border: 0xd6d1de, primary: 0xa82c87, primaryForeground: 0xfffaff, primaryText: 0xa82c87, secondary: 0xedeaf4)
        }
    }

    var dark: PaletteHalf {
        switch self {
        case .standard: .init(screen: 0x0a0a0a, card: 0x111111, groupedCard: 0x1a1b1b, foreground: 0xf5f5f5, secondaryText: 0x838383, border: 0x191919, primary: 0x346bf1, primaryForeground: 0xffffff, primaryText: 0x4b7cf3, secondary: 0x111111)
        case .t3chat: .init(screen: 0x1f1a24, card: 0x29232d, groupedCard: 0x29232d, foreground: 0xf9f8fb, secondaryText: 0xe7d0dd, border: 0x27242c, primary: 0xa3004c, primaryForeground: 0xfbd0e8, primaryText: 0xd07ea4, secondary: 0x362d3d)
        case .grove: .init(screen: 0x1b2821, card: 0x1b2821, groupedCard: 0x253e31, foreground: 0xfffaff, secondaryText: 0xafb1b1, border: 0x415f4f, primary: 0xe3b34e, primaryForeground: 0x241523, primaryText: 0xe3b34e, secondary: 0x2a4b39)
        case .ocean: .init(screen: 0x17212b, card: 0x17212b, groupedCard: 0x233544, foreground: 0xfffaff, secondaryText: 0xa5a7ad, border: 0x405567, primary: 0x5bd0d6, primaryForeground: 0x241523, primaryText: 0x5bd0d6, secondary: 0x293f52)
        case .ember: .init(screen: 0x291e1a, card: 0x291e1a, groupedCard: 0x432e23, foreground: 0xfffaff, secondaryText: 0xaca5a6, border: 0x664c3f, primary: 0xf78a7a, primaryForeground: 0x241523, primaryText: 0xf78a7a, secondary: 0x513728)
        case .iris: .init(screen: 0x1d1929, card: 0x1d1929, groupedCard: 0x2d2643, foreground: 0xfffaff, secondaryText: 0xa09da6, border: 0x4d4366, primary: 0xf099d8, primaryForeground: 0x241523, primaryText: 0xf099d8, secondary: 0x362d51)
        }
    }
}

/// Die aktive App-Palette: Farben passen sich automatisch an hell/dunkel an.
struct AppTheme {
    var light: PaletteID
    var dark: PaletteID

    static let lightKey = "theme.light"
    static let darkKey = "theme.dark"
    /// Wie in den t3code-Einstellungen des Nutzers: hell Iris, dunkel Grove.
    static let defaultLight = PaletteID.iris
    static let defaultDark = PaletteID.grove

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

    /// Kräftige, aber zur Palette passende Zustandsfarben (z. B. Filter „muss“ / „ausschließen“).
    var include: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x4ade80) : UIColor(hex: 0x15803d) }) }
    var exclude: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xff6467) : UIColor(hex: 0xc10007) }) }
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

