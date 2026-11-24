import SwiftUI
import UIKit

/// Scharnier des iPhone Duo (Falt-iPhone). `.none` auf Geräten ohne Scharnier und vor iOS 27.1.
enum HingeState: Equatable {
    case none, closed, halfOpen, open
}

extension EnvironmentValues {
    /// Stand des Scharniers, gemeldet von der `HingeProbe` in `RootView`.
    @Entry var hinge: HingeState = .none
}

/// Unsichtbare Ansicht, die das Scharnier beobachtet (`UIHingeInteraction`) und ihr Fenster meldet.
/// Beim Auf- und Zuklappen wechselt die App den Bildschirm – dann fragt iOS die erlaubten Ausrichtungen neu ab
/// (`AppDelegate`: Hochformat auf dem Außenbildschirm, alle auf dem Innenbildschirm).
struct HingeProbe: UIViewRepresentable {
    var onChange: (HingeState) -> Void = { _ in }
    var onWindow: (UIWindow?) -> Void = { _ in }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        view.onWindow = onWindow
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak view] _, update in
                let state: HingeState = switch update.hinge?.status {
                case .closed: .closed
                case .partiallyOpen: .halfOpen
                case .fullyOpen: .open
                default: .none
                }
                view?.report(state)
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.onWindow = onWindow
    }

    final class ProbeView: UIView {
        var onChange: (HingeState) -> Void = { _ in }
        var onWindow: (UIWindow?) -> Void = { _ in }
        private var last: HingeState?

        func report(_ state: HingeState) {
            guard state != last else { return }
            last = state
            onChange(state)
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindow(window)
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

/// Ausrichtung: Auf iPhone-Bildschirmen nur Hochformat (Wunsch des Nutzers), auf großen Bildschirmen alle –
/// der aufgeklappte Innenbildschirm des iPhone Duo liegt quer, im Hochformat stünde die App dort seitlich
/// und das Scharnier liefe quer durch den Text. Maßgeblich ist der Bildschirm des Fensters, nicht der Gerätetyp.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let screen = window?.windowScene?.screen else { return .portrait }
        let shortSide = min(screen.bounds.width, screen.bounds.height)
        return shortSide >= 600 ? .all : .portrait
    }
}
