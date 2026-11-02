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
final class ReadAloudPlayer: NSObject, AVSpeechSynthesizerDelegate {
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
    var rate: Double = UserDefaults.standard.object(forKey: rateKey) as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            restartAtSentence()
        }
    }

    /// Wird vom Ton-Teil gelesen (anderer Thread): Lautstärketasten-Blättern lässt die Audiositzung dann in Ruhe.
    nonisolated(unsafe) static var sessionInUse = false
    private static let audioQueue = DispatchQueue(label: "babel.read-aloud", qos: .userInitiated)

    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    /// Ab welcher Stelle des Absatzes die aktuelle Äußerung beginnt (nach Tempo-/Stimmenwechsel mitten im Absatz).
    private var utteranceOffset = 0
    private var sentences: [(range: NSRange, text: String)] = []
    private var sentenceIndex = 0
    private var loadTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var resumeAfterInterruption = false
    private var artwork: MPMediaItemArtwork?

    override init() {
        super.init()
        synth.delegate = self
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
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        updateNowPlaying()
    }

    func resume() {
        guard let story else { return }
        if paragraphs.isEmpty { load(chapter: chapter, startAt: paragraph); return }
        isPlaying = true
        activateSession {
            if self.synth.isPaused { self.synth.continueSpeaking() } else { self.speakCurrent(from: self.sentenceStart) }
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
        utterance = nil
        synth.stopSpeaking(at: .immediate)
        isPlaying = false
        isLoading = false
        story = nil
        paragraphs = []
        cursor = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        Self.sessionInUse = false
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

    /// Alle passenden Stimmen für die Sprache des Kapitels, beste zuerst.
    var voices: [AVSpeechSynthesisVoice] { Self.voices(for: language) }

    var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices.first
    }

    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        UserDefaults.standard.set(voice?.identifier, forKey: voiceKey)
        restartAtSentence()
    }

    private var voiceKey: String { "readAloud.voice.\(language)" }

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
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
        synth.stopSpeaking(at: .immediate)
        utterance = nil
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
                self.language = Self.detectLanguage(blocks)
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
        prepareSentences()
        savePosition(story)
        if speak { activateSession { self.speakCurrent(from: 0) } } else { utterance = nil; synth.stopSpeaking(at: .immediate) }
        updateNowPlaying()
    }

    private var sentenceStart: Int { sentences.indices.contains(sentenceIndex) ? sentences[sentenceIndex].range.location : 0 }

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
    private func speakCurrent(from offset: Int) {
        guard isPlaying, paragraphs.indices.contains(paragraph) else { return }
        let text = paragraphs[paragraph] as NSString
        let start = min(max(0, offset), text.length)
        let next = AVSpeechUtterance(string: text.substring(from: start))
        next.voice = voice
        next.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), Double(AVSpeechUtteranceDefaultSpeechRate) * rate))
        next.postUtteranceDelay = 0.15
        utteranceOffset = start
        utterance = next
        synth.stopSpeaking(at: .immediate)
        synth.speak(next)
    }

    private func restartAtSentence() {
        guard isPlaying, !paragraphs.isEmpty, utterance != nil else { return }
        speakCurrent(from: sentenceStart)
    }

    private func didFinish(_ id: ObjectIdentifier) {
        guard let utterance, ObjectIdentifier(utterance) == id, isPlaying else { return }
        self.utterance = nil
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

    private func willSpeak(_ id: ObjectIdentifier, range: NSRange) {
        guard let utterance, ObjectIdentifier(utterance) == id else { return }
        let location = utteranceOffset + range.location
        guard let index = sentences.lastIndex(where: { $0.range.location <= location }), index != sentenceIndex else { return }
        sentenceIndex = index
        updateCursor()
    }

    private func finish() {
        isPlaying = false
        utterance = nil
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

    private func activateSession(_ then: @escaping @MainActor () -> Void) {
        Self.sessionInUse = true
        Self.audioQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? session.setActive(true)
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
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

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.didFinish(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.willSpeak(id, range: characterRange) } }
    }
}
