import SwiftUI

/// Wählbare Farben des App-Icons. Die Icon-Dateien (`AppIcon.icon`, `AppIcon-<Name>.icon`) und die
/// Vorschaubilder erzeugt `Design/Icon/make-icons.py`; die Namen müssen auch in `project.yml` stehen.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case weinrot = "Weinrot"
    case jade = "Jade"
    case waldnacht = "Waldnacht"
    case tiefsee = "Tiefsee"
    case nachtblau = "Nachtblau"
    case pflaume = "Pflaume"
    case rost = "Rost"
    case senf = "Senf"
    case sand = "Sand"
    case tinte = "Tinte"

    static let standard = AppIconChoice.weinrot
    var id: String { rawValue }

    /// Name für `setAlternateIconName` – das Standard-Icon ist `nil`.
    var iconName: String? { self == Self.standard ? nil : "AppIcon-\(rawValue)" }
    var previewName: String { "IconPreview-\(rawValue)" }

    var label: String {
        switch self {
        case .weinrot: String(localized: "Weinrot")
        case .jade: String(localized: "Jade")
        case .waldnacht: String(localized: "Waldnacht")
        case .tiefsee: String(localized: "Tiefsee")
        case .nachtblau: String(localized: "Nachtblau")
        case .pflaume: String(localized: "Pflaume")
        case .rost: String(localized: "Rost")
        case .senf: String(localized: "Senf")
        case .sand: String(localized: "Sand")
        case .tinte: String(localized: "Tinte")
        }
    }

    @MainActor static var current: AppIconChoice {
        guard let name = UIApplication.shared.alternateIconName else { return standard }
        return allCases.first { $0.iconName == name } ?? standard
    }
}

/// Zeile in den Einstellungen: aktuelles Icon, führt zur Auswahl.
struct AppIconSettingsRow: View {
    @State private var current = AppIconChoice.standard

    var body: some View {
        NavigationLink {
            AppIconSettingsView(current: $current)
        } label: {
            HStack(spacing: 14) {
                Image(current.previewName)
                    .resizable()
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("App-Icon").font(.headline)
                    Text(current.label).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { current = AppIconChoice.current }
    }
}

struct AppIconSettingsView: View {
    @Binding var current: AppIconChoice
    @Environment(\.theme) private var theme
    @State private var failed = false

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button { select(choice) } label: { cell(choice) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choice == current ? .isSelected : [])
                }
            }
            .padding(20)
        }
        .themedBackground()
        .navigationTitle("App-Icon")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Das Icon ließ sich nicht ändern.", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func cell(_ choice: AppIconChoice) -> some View {
        VStack(spacing: 8) {
            Image(choice.previewName)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(5)
                .overlay {
                    // Form des Icons: Eckenradius ≈ 22,5 % der Kantenlänge, mit Abstand etwas mehr.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(theme.primary, lineWidth: 2.5)
                        .opacity(choice == current ? 1 : 0)
                }
            Text(choice.label)
                .font(.footnote.weight(choice == current ? .semibold : .regular))
                .foregroundStyle(choice == current ? AnyShapeStyle(theme.primaryText) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    private func select(_ choice: AppIconChoice) {
        guard choice != current, UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(choice.iconName) { error in
            Task { @MainActor in
                if error == nil { current = choice } else { failed = true }
            }
        }
    }
}
