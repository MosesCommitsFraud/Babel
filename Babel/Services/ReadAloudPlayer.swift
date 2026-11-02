import AVFoundation
import MediaPlayer
import NaturalLanguage
import SwiftSoup
import SwiftUI

/// Vorlesen mit den Stimmen von iOS. Liest Absatz für Absatz, geht am Kapitelende ins nächste Kapitel,
/// läuft im Hintergrund weiter und lässt sich über Sperrbildschirm, Kopfhörer und CarPlay steuern.
/// Der Reader markiert den gerade gesprochenen Satz (`cursor`).
@MainActor
@Observable
final class ReadAloudPlayer: NSObject {
    static let shared = ReadAloudPlayer()
    static let rateKey = "readAloud.rate"

    /// Absätze werden in Swift und im Reader-JavaScript gleich gezählt: nur „Blätter“ dieser Elemente mit Text.
    nonisolated static let blockSelector = "p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, dt, dd, td"

    /// Wo gerade vorgelesen wird – der Reader markiert danach.
    struct Cursor: Equatable {
        var storyKey: String
        var chapter: Int
        var paragraph: Int
        var sentence: String?
    }

    enum SleepTimer: Equatable, Hashable {
        case off, minutes(Int), chapterEnd

        var label: String {
            switch self {
            case .off: String(localized: "Aus")
            case .minutes(let m): String(localized: "\(m) Minuten")
            case .chapterEnd: String(localized: "Ende des Kapitels")
            }
        }
    }

    private(set) var story: Story?
    private(set) var chapter = 0
    private(set) var paragraphs: [String] = []
    private(set) var paragraph = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var language = "en"
    private(set) var cursor: Cursor?
    private(set) var sleepTimer: SleepTimer = .off
    private(set) var sleepEnds: Date?
    var error: String?

    var isActive: Bool { story != nil }
    var chapterTitle: String { story?.title(ofChapter: chapter) ?? "" }

    /// Tempo als Faktor zur normalen Sprechgeschwindigkeit (0,6 … 1,6).
    /// Beim Schieben nur kurz entprellt übernommen – nicht bei jedem Zwischenwert neu starten.
    var rate: Double = UserDefaults.standard.object(forKey: rateKey) as? Double ?? 1.0 {
        didSet {
            guard rate != oldValue else { return }
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            scheduleRestart(after: .milliseconds(180))
        }
    }

    /// Stimmen der aktuellen Sprache, beste zuerst – einmal je Sprache geladen (die iOS-Abfrage ist langsam).
    private(set) var voices: [AVSpeechSynthesisVoice] = []
    private(set) var voiceID: String?

    /// Wird vom Ton-Teil gelesen (anderer Thread): Lautstärketasten-Blättern lässt die Audiositzung dann in Ruhe.
    nonisolated(unsafe) static var sessionInUse = false
    private static let audioQueue = DispatchQueue(label: "babel.read-aloud", qos: .userInitiated)

    private let engine = SpeechEngine()
    /// Nummer der laufenden Äußerung – Rückmeldungen älterer (abgebrochener) Äußerungen werden ignoriert.
    private var token = 0
    private var speaking = false
    /// Pausiert mitten in einer Äußerung → beim Fortsetzen dort weiter. Nach Tempo-/Stimmenwechsel neu ansetzen.
    private var pausedInUtterance = false
    private var sessionActive = false
    /// Ab welcher Stelle des Absatzes die aktuelle Äußerung beginnt (nach Tempo-/Stimmenwechsel mitten im Absatz).
    private var utteranceOffset = 0
    /// Beginn des gerade gesprochenen Worts im Absatz – dort setzt ein Neustart wieder an.
    private var wordLocation = 0
    private var restartTask: Task<Void, Never>?
    private var voicesTask: Task<Void, Never>?
    private var sentences: [(range: NSRange, text: String)] = []
    private var sentenceIndex = 0
    private var loadTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var resumeAfterInterruption = false
    private var artwork: MPMediaItemArtwork?

    override init() {
        super.init()
        engine.onWord = { [weak self] token, range in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.willSpeak(token, range: range) } }
        }
        engine.onFinish = { [weak self] token in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didFinish(token) } }
        }
        loadVoices(for: language)
        setUpRemoteCommands()
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { self?.interruption(type, shouldResume: options?.contains(.shouldResume) ?? false) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Kopfhörer abgezogen → anhalten, nicht über den Lautsprecher weiterreden.
            if reason == .oldDeviceUnavailable { MainActor.assumeIsolated { self?.pause() } }
        }
    }

    // MARK: - Steuerung

    /// Ab einem Absatz eines Kapitels vorlesen (lädt das Kapitel, falls nötig).
    func play(_ story: Story, chapter: Int, paragraph: Int = 0) {
        let sameStory = self.story?.key == story.key
        if !sameStory { artwork = nil }
        self.story = story
        error = nil
        if sameStory, chapter == self.chapter, !paragraphs.isEmpty, loadTask == nil {
            start(at: paragraph)
            return
        }
        load(chapter: chapter, startAt: paragraph)
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        if speaking {
            engine.pause()
            pausedInUtterance = true
        }
        updateNowPlaying()
    }

    func resume() {
        guard let story else { return }
        if paragraphs.isEmpty { load(chapter: chapter, startAt: paragraph); return }
        isPlaying = true
        activateSession()
        if pausedInUtterance {
            pausedInUtterance = false
            engine.resume()
        } else {
            speakCurrent(from: wordLocation)
        }
        story.lastOpenedAt = .now
        updateNowPlaying()
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        sleepTask?.cancel()
        sleepTimer = .off
        sleepEnds = nil
        restartTask?.cancel()
        token += 1
        speaking = false
        pausedInUtterance = false
        engine.stop()
        isPlaying = false
        isLoading = false
        story = nil
        paragraphs = []
        cursor = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        Self.sessionInUse = false
        sessionActive = false
        Self.audioQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func nextParagraph() {
        guard isActive else { return }
        if paragraph + 1 < paragraphs.count { start(at: paragraph + 1) } else { nextChapter() }
    }

    func previousParagraph() {
        guard isActive else { return }
        start(at: max(0, paragraph - 1))
    }

    func nextChapter() {
        guard let story, chapter + 1 < story.knownChapterCount else { return }
        load(chapter: chapter + 1, startAt: 0)
    }

    func previousChapter() {
        guard isActive else { return }
        // Wie bei Musik: erst an den Kapitelanfang, dann ein Kapitel zurück.
        if paragraph > 1 || chapter == 0 { start(at: 0) } else { load(chapter: chapter - 1, startAt: 0) }
    }

    func setSleepTimer(_ timer: SleepTimer) {
        sleepTask?.cancel()
        sleepTimer = timer
        sleepEnds = nil
        guard case .minutes(let m) = timer else { return }
        let end = Date().addingTimeInterval(Double(m) * 60)
        sleepEnds = end
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(m) * 60))
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepTimer = .off
            self.sleepEnds = nil
        }
    }

    // MARK: - Stimmen

    func setVoice(_ id: String) {
        guard id != voiceID else { return }
        voiceID = id
        UserDefaults.standard.set(id, forKey: voiceKey)
        engine.prepare(voice: id)
        scheduleRestart(after: .zero)
    }

    private var voiceKey: String { "readAloud.voice.\(language)" }

    /// Stimmenliste im Hintergrund holen; gewählte (oder beste) Stimme gleich vorladen.
    private func loadVoices(for language: String) {
        voicesTask?.cancel()
        let saved = UserDefaults.standard.string(forKey: "readAloud.voice.\(language)")
        voicesTask = Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { Self.voices(for: language) }.value
            guard let self, !Task.isCancelled, self.language == language else { return }
            self.voices = list
            let id = list.first(where: { $0.identifier == saved })?.identifier ?? list.first?.identifier
            if id != self.voiceID {
                self.voiceID = id
                if let id { self.engine.prepare(voice: id) }
            }
        }
    }

    nonisolated static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let region = Locale.current.region?.identifier ?? ""
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                let ar = a.language.hasSuffix(region), br = b.language.hasSuffix(region)
                if ar != br { return ar }
                return a.name < b.name
            }
    }

    // MARK: - Kapitel laden

    private func load(chapter index: Int, startAt start: Int) {
        guard let story else { return }
        loadTask?.cancel()
        token += 1
        speaking = false
        pausedInUtterance = false
        engine.stop()
        chapter = index
        paragraph = start
        isLoading = true
        isPlaying = true
        cursor = Cursor(storyKey: story.key, chapter: index, paragraph: start, sentence: nil)
        updateNowPlaying()
        loadTask = Task { [weak self] in
            do {
                let url = try await LibraryManager.shared.ensureChapter(story, index: index)
                let blocks = try await Task.detached(priority: .userInitiated) { () throws -> [String] in
                    let data = try Data(contentsOf: url)
                    let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    return try Self.blocks(from: html)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.loadTask = nil
                self.isLoading = false
                self.paragraphs = blocks
                let language = Self.detectLanguage(blocks)
                if language != self.language || self.voices.isEmpty {
                    self.language = language
                    self.voiceID = nil
                    self.loadVoices(for: language)
                }
                guard !blocks.isEmpty else {
                    // Leeres Kapitel (z. B. nur Bilder) – gleich weiter.
                    if index + 1 < story.knownChapterCount { self.load(chapter: index + 1, startAt: 0) } else { self.finish() }
                    return
                }
                // Während des Ladens pausiert? Dann nur die Stelle merken.
                self.start(at: min(start, blocks.count - 1), speak: self.isPlaying)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.loadTask = nil
                self.isLoading = false
                self.isPlaying = false
                self.error = error.localizedDescription
                self.updateNowPlaying()
            }
        }
    }

    /// Text-Blöcke in Lesereihenfolge – dieselbe Zählung wie `window.babelBlocks()` im Reader.
    nonisolated static func blocks(from html: String) throws -> [String] {
        let doc = try SwiftSoup.parse(html)
        guard let body = doc.body() else { return [] }
        var result: [String] = []
        for element in try body.select(blockSelector).array() {
            // Nur innerste Blöcke (ein <li> mit <p> darin zählt über das <p>). `select` enthält das Element selbst.
            guard try element.select(blockSelector).size() == 1 else { continue }
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(text) }
        }
        if result.isEmpty {
            let text = try body.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result = [text] }
        }
        return result
    }

    private static func detectLanguage(_ blocks: [String]) -> String {
        let sample = blocks.prefix(40).joined(separator: " ").prefix(4000)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample))
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    // MARK: - Sprechen

    private func start(at index: Int, speak: Bool = true) {
        guard let story, paragraphs.indices.contains(index) else { return }
        paragraph = index
        isPlaying = speak
        pausedInUtterance = false
        wordLocation = 0
        prepareSentences()
        savePosition(story)
        if speak {
            activateSession()
            speakCurrent(from: 0)
        } else {
            token += 1
            speaking = false
            engine.stop()
        }
        updateNowPlaying()
    }

    private func prepareSentences() {
        let text = paragraphs[paragraph]
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { range in
            (NSRange(range, in: text), String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if sentences.isEmpty { sentences = [(NSRange(location: 0, length: (text as NSString).length), text)] }
        sentenceIndex = 0
        updateCursor()
    }

    /// Spricht den aktuellen Absatz ab `offset` (UTF-16) – nach Tempo- oder Stimmenwechsel mitten im Absatz.
    /// `restart`: laufende Äußerung sofort ersetzen (neue Synthese-Instanz, sonst verschluckt iOS die neue teils).
    private func speakCurrent(from offset: Int, restart: Bool = false) {
        guard isPlaying, paragraphs.indices.contains(paragraph) else { return }
        let text = paragraphs[paragraph] as NSString
        let start = min(max(0, offset), text.length)
        utteranceOffset = start
        wordLocation = start
        token += 1
        speaking = true
        let rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), Double(AVSpeechUtteranceDefaultSpeechRate) * self.rate))
        engine.speak(text.substring(from: start), voice: voiceID, rate: rate, token: token, restart: restart)
    }

    /// Tempo/Stimme geändert: am gerade gesprochenen Wort mit den neuen Werten weiter.
    private func scheduleRestart(after delay: Duration) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, !self.paragraphs.isEmpty else { return }
            if self.isPlaying {
                if self.speaking { self.speakCurrent(from: self.wordLocation, restart: true) }
            } else if self.pausedInUtterance {
                // Pausiert: beim Fortsetzen mit den neuen Werten neu ansetzen statt alt weiterzusprechen.
                self.pausedInUtterance = false
                self.token += 1
                self.speaking = false
                self.engine.stop()
            }
        }
    }

    private func didFinish(_ finished: Int) {
        guard finished == token, isPlaying else { return }
        speaking = false
        if paragraph + 1 < paragraphs.count {
            start(at: paragraph + 1)
        } else if sleepTimer == .chapterEnd {
            pause()
            setSleepTimer(.off)
            if let story, chapter + 1 < story.knownChapterCount { chapter += 1; paragraph = 0; paragraphs = []; savePosition(story) }
        } else if let story, chapter + 1 < story.knownChapterCount {
            load(chapter: chapter + 1, startAt: 0)
        } else {
            finish()
        }
    }

    private func willSpeak(_ spoken: Int, range: NSRange) {
        guard spoken == token else { return }
        let location = utteranceOffset + range.location
        wordLocation = location
        guard let index = sentences.lastIndex(where: { $0.range.location <= location }), index != sentenceIndex else { return }
        sentenceIndex = index
        updateCursor()
    }

    private func finish() {
        isPlaying = false
        speaking = false
        updateNowPlaying()
    }

    private func updateCursor() {
        guard let story else { cursor = nil; return }
        let sentence = sentences.indices.contains(sentenceIndex) ? sentences[sentenceIndex].text : nil
        cursor = Cursor(storyKey: story.key, chapter: chapter, paragraph: paragraph, sentence: sentence)
    }

    /// Fortschritt mitschreiben, damit „Weiterlesen“ nach dem Zuhören an der richtigen Stelle landet.
    private func savePosition(_ story: Story) {
        story.currentChapter = chapter
        if !paragraphs.isEmpty { story.chapterProgress = Double(paragraph) / Double(paragraphs.count) }
        story.lastOpenedAt = .now
        try? story.modelContext?.save()
    }

    // MARK: - Audiositzung

    /// Einmal pro Vorlese-Sitzung, im Hintergrund – nicht vor jedem Absatz (das gab Pausen dazwischen).
    private func activateSession() {
        Self.sessionInUse = true
        guard !sessionActive else { return }
        sessionActive = true
        Self.audioQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? session.setActive(true)
        }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            sessionActive = false
            resumeAfterInterruption = isPlaying
            pause()
        case .ended:
            if resumeAfterInterruption && shouldResume { resume() }
            resumeAfterInterruption = false
        default:
            break
        }
    }

    // MARK: - Sperrbildschirm & Fernbedienung

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ReadAloudPlayer) -> Void) {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return .noActionableNowPlayingItem }
                    action(self)
                    return .success
                }
            }
        }
        handle(center.playCommand) { $0.resume() }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.togglePlayPauseCommand) { $0.toggle() }
        handle(center.nextTrackCommand) { $0.nextChapter() }
        handle(center.previousTrackCommand) { $0.previousChapter() }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let story else { return }
        if artwork == nil, let url = ContentStore.coverFileURL(story), let image = UIImage(contentsOfFile: url.path) {
            artwork = Self.artwork(image)
        }
        let fraction = paragraphs.isEmpty ? 0 : Double(paragraph) / Double(paragraphs.count)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: story.title(ofChapter: chapter),
            MPMediaItemPropertyArtist: story.author,
            MPMediaItemPropertyAlbumTitle: story.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackProgress: Float(fraction),
            MPNowPlayingInfoPropertyChapterNumber: chapter,
            MPNowPlayingInfoPropertyChapterCount: story.knownChapterCount,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// Außerhalb des MainActors: iOS ruft den Bild-Block auf einem beliebigen Thread auf.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// Die eigentliche Sprachausgabe auf einer eigenen Warteschlange: Stimmen laden, Starten und Abbrechen
/// blockieren so nie die Oberfläche. Für einen Neustart mitten im Satz gibt es eine frische Synthese-Instanz –
/// direkt nach `stopSpeaking` verwirft iOS sonst teils auch die neue Äußerung.
final class SpeechEngine: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// Merkt sich, zu welcher Äußerung (Nummer) die Rückmeldungen gehören.
    private final class Synth: AVSpeechSynthesizer, @unchecked Sendable {
        var token = 0
    }

    var onWord: (@Sendable (Int, NSRange) -> Void)?
    var onFinish: (@Sendable (Int) -> Void)?

    private let queue = DispatchQueue(label: "babel.speech", qos: .userInitiated)
    private var synth: Synth?
    private var warmed: Set<String> = []
    /// Muss leben, bis die stumme Vorlade-Äußerung durch ist.
    private var warmer: AVSpeechSynthesizer?

    func speak(_ text: String, voice: String?, rate: Float, token: Int, restart: Bool) {
        queue.async {
            let synth: Synth
            if restart || self.synth == nil || self.synth?.isSpeaking == true || self.synth?.isPaused == true {
                self.discard()
                synth = Synth()
                synth.delegate = self
                self.synth = synth
            } else {
                synth = self.synth!
            }
            synth.token = token
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            utterance.rate = rate
            utterance.postUtteranceDelay = 0.1
            synth.speak(utterance)
        }
    }

    func pause() { queue.async { self.synth?.pauseSpeaking(at: .word) } }
    func resume() { queue.async { self.synth?.continueSpeaking() } }
    func stop() { queue.async { self.discard() } }

    /// Stimme einmal stumm laden, damit der Wechsel später ohne Wartezeit klappt.
    func prepare(voice id: String) {
        queue.async {
            guard !self.warmed.contains(id), let voice = AVSpeechSynthesisVoice(identifier: id) else { return }
            self.warmed.insert(id)
            let warm = AVSpeechSynthesizer()
            self.warmer = warm
            let utterance = AVSpeechUtterance(string: "a")
            utterance.voice = voice
            utterance.volume = 0
            // Nur rendern, nichts abspielen – lädt die Stimme in den Speicher.
            warm.write(utterance) { _ in }
        }
    }

    private func discard() {
        guard let old = synth else { return }
        old.delegate = nil
        old.stopSpeaking(at: .immediate)
        synth = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let synth = synthesizer as? Synth else { return }
        onWord?(synth.token, characterRange)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let synth = synthesizer as? Synth else { return }
        onFinish?(synth.token)
    }
}
