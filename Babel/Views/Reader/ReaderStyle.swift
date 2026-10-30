import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark, black
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "Auto"); case .light: String(localized: "Hell"); case .sepia: String(localized: "Sepia"); case .dark: String(localized: "Dunkel"); case .black: String(localized: "Schwarz")
        }
    }

    func resolved(_ scheme: ColorScheme) -> ReaderTheme {
        self == .system ? (scheme == .dark ? .dark : .light) : self
    }

    var background: String {
        switch self {
        case .system, .light: "#FBFAF7"; case .sepia: "#F3E9D2"; case .dark: "#1C1C1E"; case .black: "#000000"
        }
    }

    var foreground: String {
        switch self {
        case .system, .light: "#1C1C1E"; case .sepia: "#4A3B2A"; case .dark: "#E6E6E9"; case .black: "#CFCFD3"
        }
    }

    var link: String {
        switch self {
        case .system, .light: "#2F5BD3"; case .sepia: "#8A4B14"; case .dark, .black: "#7EA6FF"
        }
    }

    var colorScheme: ColorScheme { self == .dark || self == .black ? .dark : .light }

    var swiftUIBackground: Color { Color(hex: background) }
    var swiftUIForeground: Color { Color(hex: foreground) }
}

struct ReaderFont: Identifiable, Hashable {
    let id: String
    let name: String
    let css: String

    static let all: [ReaderFont] = [
        .init(id: "newyork", name: "New York", css: "ui-serif, 'New York', Georgia, serif"),
        .init(id: "system", name: "San Francisco", css: "-apple-system, system-ui, sans-serif"),
        .init(id: "rounded", name: "SF Rounded", css: "ui-rounded, -apple-system, sans-serif"),
        .init(id: "charter", name: "Charter", css: "Charter, 'Iowan Old Style', Georgia, serif"),
        .init(id: "georgia", name: "Georgia", css: "Georgia, serif"),
        .init(id: "iowan", name: "Iowan Old Style", css: "'Iowan Old Style', Palatino, serif"),
        .init(id: "palatino", name: "Palatino", css: "Palatino, 'Palatino Linotype', serif"),
        .init(id: "avenir", name: "Avenir Next", css: "'Avenir Next', Avenir, sans-serif"),
    ]

    static func find(_ id: String) -> ReaderFont { all.first { $0.id == id } ?? all[0] }
}

/// Liest die Reader-Einstellungen und baut das CSS, das in jedes Kapitel gespritzt wird.
struct ReaderStyle {
    var theme: ReaderTheme
    var font: ReaderFont
    var fontSize: Double
    var lineHeight: Double
    var margin: Double
    var justify: Bool
    var paragraphSpacing: Double

    var css: String {
        """
        :root { color-scheme: \(theme.colorScheme == .dark ? "dark" : "light"); }
        html { -webkit-text-size-adjust: 100%; background: \(theme.background) !important; overflow-x: hidden !important; }
        body { overflow-x: hidden !important; }
        pre, table { white-space: pre-wrap; max-width: 100% !important; }
        body {
            margin: 0 !important;
            padding: calc(env(safe-area-inset-top) + 72px) \(Int(margin))px calc(env(safe-area-inset-bottom) + 120px) \(Int(margin))px !important;
            background: \(theme.background) !important;
            color: \(theme.foreground) !important;
            font-family: \(font.css) !important;
            font-size: \(Int(fontSize))px !important;
            line-height: \(lineHeight) !important;
            text-align: \(justify ? "justify" : "start") !important;
            -webkit-hyphens: auto; hyphens: auto;
            overflow-wrap: break-word;
            max-width: none !important;
        }
        body * {
            color: inherit !important;
            background-color: transparent !important;
            font-family: inherit !important;
            line-height: inherit !important;
            max-width: 100% !important;
        }
        p { margin: 0 0 \(paragraphSpacing)em 0 !important; }
        img, svg, video { max-width: 100% !important; height: auto !important; }
        a { color: \(theme.link) !important; }
        h1, h2, h3, h4 { line-height: 1.25 !important; text-align: start !important; }
        hr { border: none !important; border-top: 1px solid currentColor !important; opacity: .25; margin: 2em 0 !important; }
        blockquote { margin-left: 1em !important; padding-left: .8em !important; border-left: 2px solid currentColor; opacity: .92; }
        .babel-title { font-size: 1.45em !important; font-weight: 700 !important; margin: 0 0 1.2em 0 !important; letter-spacing: -0.01em; }
        .babel-notes { font-size: .88em !important; opacity: .82; border-left: 3px solid \(theme.link) !important; padding: .2em 0 .2em .9em !important; margin: 1.2em 0 2em 0 !important; }
        .babel-notes.end { margin-top: 3em !important; }
        .babel-notes-label { font-weight: 700 !important; text-transform: uppercase; letter-spacing: .06em; font-size: .78em !important; opacity: .7; margin-bottom: .5em !important; }
        """
    }
}

/// Standard-Leseeinstellungen: Iowan Old Style, Zeilenabstand 1,2, Absatz 0,9, Rand 14 pt, Blocksatz.
enum ReaderDefaults {
    static let font = "iowan"
    static let fontSize = 19.0
    static let lineHeight = 1.2
    static let margin = 14.0
    static let justify = true
    static let paragraphSpacing = 0.9

    /// Einmal auf die neuen Standards umstellen – vorher gespeicherte Werte (alte Standards) würden sonst bleiben.
    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "reader.defaults.v2") else { return }
        defaults.set(font, forKey: "reader.font")
        defaults.set(lineHeight, forKey: "reader.lineHeight")
        defaults.set(margin, forKey: "reader.margin")
        defaults.set(justify, forKey: "reader.justify")
        defaults.set(paragraphSpacing, forKey: "reader.paragraphSpacing")
        defaults.set(true, forKey: "reader.defaults.v2")
    }
}

/// Gemeinsame Einstellungs-Steuerelemente (im Reader-Sheet und in den Einstellungen).
struct ReaderSettingsControls: View {
    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.font") private var fontID = ReaderDefaults.font
    @AppStorage("reader.fontSize") private var fontSize = ReaderDefaults.fontSize
    @AppStorage("reader.lineHeight") private var lineHeight = ReaderDefaults.lineHeight
    @AppStorage("reader.margin") private var margin = ReaderDefaults.margin
    @AppStorage("reader.justify") private var justify = ReaderDefaults.justify
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = ReaderDefaults.paragraphSpacing
    @AppStorage(VolumeKeyScroller.settingKey) private var volumeScroll = false

    var body: some View {
        Section("Farbe") {
            HStack(spacing: 12) {
                ForEach(ReaderTheme.allCases) { t in
                    Button {
                        theme = t
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(t == .system
                                      ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "#FBFAF7"), Color(hex: "#1C1C1E")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                      : AnyShapeStyle(t.swiftUIBackground))
                                .overlay(Text("Aa").font(.caption.weight(.semibold)).foregroundStyle(t == .system ? .gray : t.swiftUIForeground))
                                .overlay(Circle().strokeBorder(theme == t ? Color.accentColor : .gray.opacity(0.3), lineWidth: theme == t ? 3 : 1))
                                .frame(width: 44, height: 44)
                            Text(t.label).font(.caption2)
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }

        Section("Schrift") {
            Picker("Schriftart", selection: $fontID) {
                ForEach(ReaderFont.all) { f in Text(f.name).tag(f.id) }
            }
            HStack {
                Text("Größe")
                Spacer()
                Text("\(Int(fontSize))").monospacedDigit().foregroundStyle(.secondary)
                Stepper("Größe", value: $fontSize, in: 12...34, step: 1).labelsHidden()
            }
            VStack(alignment: .leading) {
                Text("Zeilenabstand \(lineHeight, format: .number.precision(.fractionLength(1)))")
                Slider(value: $lineHeight, in: 1.2...2.2, step: 0.1)
            }
            VStack(alignment: .leading) {
                Text("Absatzabstand \(paragraphSpacing, format: .number.precision(.fractionLength(1)))")
                Slider(value: $paragraphSpacing, in: 0...2, step: 0.1)
            }
            VStack(alignment: .leading) {
                Text("Seitenrand \(Int(margin)) pt")
                Slider(value: $margin, in: 8...48, step: 2)
            }
            Toggle("Blocksatz", isOn: $justify)
            Button("Auf Standard zurücksetzen", systemImage: "arrow.counterclockwise") {
                fontID = ReaderDefaults.font
                fontSize = ReaderDefaults.fontSize
                lineHeight = ReaderDefaults.lineHeight
                margin = ReaderDefaults.margin
                justify = ReaderDefaults.justify
                paragraphSpacing = ReaderDefaults.paragraphSpacing
            }
        }

        Section {
            Toggle("Mit Lautstärketasten blättern", isOn: $volumeScroll)
        } header: {
            Text("Bedienung")
        } footer: {
            Text("Leiser scrollt eine Bildschirmseite weiter, lauter zurück. Am Kapitelende geht es mit „leiser“ zum nächsten Kapitel. Die Lautstärke bleibt dabei unverändert.")
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
