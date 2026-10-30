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
    private var lastVolume: Float = 0.5
    private var original: Float?
    /// Zählt Start/Stop hoch, damit eine verspätete Aktivierung nach `stop()` nichts mehr einrichtet.
    private var generation = 0
    private(set) var isRunning = false

    /// Aktivieren/Deaktivieren blockiert – nie auf dem Main Thread.
    private static let audioQueue = DispatchQueue(label: "babel.volume-keys", qos: .userInitiated)

    private var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let token = generation

        // Muss früh im Fenster hängen, sonst zeigt iOS beim ersten Druck noch die Lautstärkeanzeige.
        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        keyWindow?.addSubview(view)
        volumeView = view

        Self.audioQueue.async {
            let session = AVAudioSession.sharedInstance()
            // Mischt sich mit laufender Musik, unterbricht nichts.
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true)
            let current = session.outputVolume
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.generation == token else { return }
                self.begin(at: current)
            }
        }
    }

    private func begin(at current: Float) {
        // Ganz laut oder ganz leise gäbe es in eine Richtung keine Änderung – eine Stufe hereinrücken.
        original = current
        baseline = min(max(current, 1 / 16), 15 / 16)
        lastVolume = current
        if baseline != current { setVolume(baseline) }

        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            DispatchQueue.main.async { self?.volumeChanged(volume) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        observation?.invalidate()
        observation = nil
        if let original, original != baseline { setVolume(original) }
        original = nil
        // Kurz warten, damit das Zurücksetzen noch ohne Anzeige durchgeht.
        let view = volumeView
        volumeView = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            view?.removeFromSuperview()
        }
        Self.audioQueue.asyncAfter(deadline: .now() + 0.5) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Jede Änderung weg vom Ausgangswert ist ein Tastendruck – auch mehrere schnell hintereinander,
    /// bevor das Zurücksetzen greift. Die Rückkehr zum Ausgangswert ist das eigene Zurücksetzen.
    private func volumeChanged(_ volume: Float) {
        defer { lastVolume = volume }
        guard abs(volume - baseline) > 0.001 else { return }
        let delta = volume - lastVolume
        guard abs(delta) > 0.001 else { return }
        onPress?(delta < 0 ? 1 : -1)
        setVolume(baseline)
    }

    private func setVolume(_ value: Float) {
        slider?.value = value
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
