import AVFoundation
import MediaPlayer
import UIKit

/// Blättern mit den Lautstärketasten. iOS hat dafür kein API außerhalb von Kamera-Apps,
/// deshalb wird die Lautstärke beobachtet und nach jedem Tastendruck sofort zurückgesetzt.
/// Ein unsichtbarer `MPVolumeView` blendet dabei die System-Lautstärkeanzeige aus.
@MainActor
final class VolumeKeyScroller {
    static let settingKey = "reader.volumeScroll"

    /// -1 = lauter (zurück), +1 = leiser (weiter).
    var onPress: ((Int) -> Void)?

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var baseline: Float = 0.5
    private var original: Float?
    private var isResetting = false

    private var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    var isRunning: Bool { observation != nil }

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Mischt sich mit laufender Musik, unterbricht nichts.
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        keyWindow?.addSubview(view)
        volumeView = view

        // Ganz laut oder ganz leise gäbe es in eine Richtung keine Änderung – eine Stufe hereinrücken.
        let current = session.outputVolume
        original = current
        baseline = min(max(current, 1 / 16), 15 / 16)
        if baseline != current { setVolume(baseline) }

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.volumeChanged(volume) }
        }
    }

    func stop() {
        guard isRunning else { return }
        observation?.invalidate()
        observation = nil
        if let original, original != baseline { setVolume(original) }
        original = nil
        // Kurz warten, damit das Zurücksetzen noch ohne Anzeige durchgeht.
        let view = volumeView
        volumeView = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            view?.removeFromSuperview()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func volumeChanged(_ volume: Float) {
        if isResetting {
            if abs(volume - baseline) < 0.001 { isResetting = false }
            return
        }
        guard abs(volume - baseline) > 0.001 else { return }
        onPress?(volume < baseline ? 1 : -1)
        setVolume(baseline)
    }

    private func setVolume(_ value: Float) {
        isResetting = true
        // Der Regler übernimmt den Wert erst im nächsten Durchlauf zuverlässig.
        DispatchQueue.main.async { [weak self] in
            self?.slider?.value = value
        }
        // Falls keine Rückmeldung kommt, nicht dauerhaft blockieren.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.isResetting = false }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
