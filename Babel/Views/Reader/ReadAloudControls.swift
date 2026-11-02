import AVFoundation
import SwiftUI

/// Steuerung fürs Vorlesen: Wiedergabe, Tempo, Stimme, Sleep-Timer.
struct ReadAloudSheet: View {
    @State private var player = ReadAloudPlayer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Text(player.chapterTitle).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                        if !player.paragraphs.isEmpty {
                            Text("Absatz \(player.paragraph + 1) von \(player.paragraphs.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            ProgressView(value: Double(player.paragraph + 1), total: Double(max(player.paragraphs.count, 1)))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    transport
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)

                    if let error = player.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Tempo") {
                    HStack {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $player.rate, in: 0.6...1.6, step: 0.1)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                    Text("\(player.rate, format: .number.precision(.fractionLength(1)))×")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Stimme", selection: Binding(
                        get: { player.voiceID ?? "" },
                        set: { player.setVoice($0) }
                    )) {
                        ForEach(player.voices, id: \.identifier) { voice in
                            Text(Self.label(voice)).tag(voice.identifier)
                        }
                    }
                } header: {
                    Text("Stimme")
                } footer: {
                    Text("Natürlicher klingen die Stimmen „Erweitert“ und „Premium“. Laden kannst du sie in den iOS-Einstellungen unter Bedienungshilfen → Gesprochene Inhalte → Stimmen.")
                }

                Section("Sleep-Timer") {
                    Picker("Anhalten nach", selection: Binding(get: { player.sleepTimer }, set: { player.setSleepTimer($0) })) {
                        ForEach([ReadAloudPlayer.SleepTimer.off, .minutes(15), .minutes(30), .minutes(60), .chapterEnd], id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    if let end = player.sleepEnds {
                        Text("Hält um \(end.formatted(date: .omitted, time: .shortened)) an").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Vorlesen beenden", systemImage: "stop.fill", role: .destructive) {
                        player.stop()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Vorlesen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                Button { player.previousParagraph() } label: {
                    Image(systemName: "backward.fill").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Vorheriger Absatz")

                Button { player.toggle() } label: {
                    Group {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")

                Button { player.nextParagraph() } label: {
                    Image(systemName: "forward.fill").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Nächster Absatz")
            }
        }
        .padding(.vertical, 4)
    }

    private static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let quality: String = switch voice.quality {
        case .premium: String(localized: "Premium")
        case .enhanced: String(localized: "Erweitert")
        default: String(localized: "Standard")
        }
        return "\(voice.name) · \(region) · \(quality)"
    }
}
