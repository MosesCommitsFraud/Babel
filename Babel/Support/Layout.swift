import SwiftUI

/// Wie viel Platz die App hat – nach Breite, nicht nach Gerätetyp:
/// - `compact`: iPhone hochkant.
/// - `medium`: zwischen iPhone und iPad (z. B. iPad in geteilter Ansicht). Das iPhone Duo fällt
///   **nicht** hierher: Neben seiner seitlichen Leiste bleibt dem Inhalt etwa iPhone-Breite.
/// - `wide`: iPad.
enum LayoutClass: Comparable {
    case compact, medium, wide

    init(width: CGFloat) {
        // Das breiteste normale iPhone hat 440 pt.
        self = width >= 700 ? .wide : (width >= 455 ? .medium : .compact)
    }
}

private struct LayoutClassKey: EnvironmentKey {
    static let defaultValue = LayoutClass.compact
}

private struct LayoutWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 390
}

extension EnvironmentValues {
    var layoutClass: LayoutClass {
        get { self[LayoutClassKey.self] }
        set { self[LayoutClassKey.self] = newValue }
    }

    /// Breite des Fensters in Punkten (für Spaltenzahlen).
    var layoutWidth: CGFloat {
        get { self[LayoutWidthKey.self] }
        set { self[LayoutWidthKey.self] = newValue }
    }
}

/// Misst die Breite des Inhalts **eines Tabs** und gibt sie an dessen Ansichten weiter – nicht die des Fensters:
/// Auf dem iPhone Duo legt iOS Tab-Leiste und Knöpfe als Leiste an den rechten Rand, der Inhalt ist dort
/// schmaler als das Fenster (im Simulator ~380 von 466 pt). Auf dem iPad ist außerdem alles
/// zwei Schriftstufen größer – bei Armlänge wirkt die iPhone-Größe dort klein und lässt viel Fläche leer.
struct LayoutRoot: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 390

    func body(content: Content) -> some View {
        let layout = LayoutClass(width: width)
        content
            .environment(\.layoutClass, layout)
            .environment(\.layoutWidth, width)
            .environment(\.dynamicTypeSize, layout == .wide ? Self.bumped(typeSize, by: 2) : typeSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private static func bumped(_ size: DynamicTypeSize, by steps: Int) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        guard let index = all.firstIndex(of: size) else { return size }
        // Bedienungshilfen-Größen sind schon groß genug.
        if size.isAccessibilitySize { return size }
        return all[min(index + steps, all.firstIndex(of: .xxxLarge) ?? index)]
    }
}

extension View {
    func layoutRoot() -> some View { modifier(LayoutRoot()) }
}
