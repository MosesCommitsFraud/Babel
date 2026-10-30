import SwiftUI
import SwiftData
import WebKit

/// Zustand des Readers. Jedes Kapitel ist eine eigene Seite im `ReaderPager`;
/// die Nachbarkapitel liegen schon geladen daneben, damit Wischen sofort und flüssig geht.
@MainActor
@Observable
final class ReaderModel {
    let story: Story
    var chapterIndex: Int
    var progress: Double
    /// Nur wenn das aktuelle Kapitel erst aus dem Netz kommt – lokale Kapitel zeigen kein Ladesymbol.
    var isLoading = false
    var error: String?
    var showChrome = true

    @ObservationIgnored weak var pager: ReaderPagerCoordinator?
    @ObservationIgnored var css = ""
    @ObservationIgnored let initialRestore: Double
    @ObservationIgnored private var lastSave = Date.distantPast

    init(story: Story) {
        self.story = story
        self.chapterIndex = min(story.currentChapter, max(story.knownChapterCount - 1, 0))
        self.progress = story.chapterProgress
        self.initialRestore = story.chapterProgress
    }

    var chapterCount: Int { story.knownChapterCount }
    var hasPrevious: Bool { chapterIndex > 0 }
    var hasNext: Bool { chapterIndex + 1 < chapterCount }
    var chapterTitle: String { story.title(ofChapter: chapterIndex) }
    var overall: Double { min(1, (Double(chapterIndex) + progress) / Double(max(chapterCount, 1))) }
    var isAtEnd: Bool { !hasNext && progress > 0.97 }

    func start() {
        story.lastOpenedAt = .now
        story.newChapters = 0
        if story.inLibrary, story.status == .none || story.status == .planned { story.status = .reading }
        try? story.modelContext?.save()
    }

    // MARK: - Navigation

    func next() { guard hasNext else { return }; pager?.show(chapterIndex + 1) }
    func previous() { guard hasPrevious else { return }; pager?.show(chapterIndex - 1) }

    func jump(to index: Int) {
        guard index >= 0, index < max(chapterCount, 1), index != chapterIndex else { return }
        pager?.show(index)
    }

    func retry() {
        error = nil
        pager?.reloadCurrent()
    }

    /// Eine Seite ist zur aktuellen geworden – nach dem Wischen oder einem Sprung.
    func didShow(_ index: Int, progress: Double, loading: Bool, error: String?) {
        chapterIndex = index
        self.progress = progress
        isLoading = loading
        self.error = error
        story.currentChapter = index
        story.chapterProgress = progress
        story.lastOpenedAt = .now
        try? story.modelContext?.save()
    }

    func pageState(_ index: Int, loading: Bool, error: String?) {
        guard index == chapterIndex else { return }
        isLoading = loading
        self.error = error
    }

    func pageProgress(_ index: Int, _ value: Double) {
        guard index == chapterIndex else { return }
        progress = min(1, max(0, value))
        story.chapterProgress = progress
        if Date().timeIntervalSince(lastSave) > 3 {
            lastSave = .now
            try? story.modelContext?.save()
        }
    }

    func handle(message: [String: Any], from index: Int) {
        switch message["type"] as? String {
        case "tap":
            withAnimation(.smooth(duration: 0.25)) { showChrome.toggle() }
        case "next":
            if index == chapterIndex { next() }
        default:
            break
        }
    }

    // MARK: - WebView-Skripte (pro Kapitelseite)

    func scripts(for index: Int) -> [WKUserScript] {
        let cssLiteral = Self.jsString(css)
        let hasNext = index + 1 < chapterCount
        let startScript = """
        (function(){
          var s = document.createElement('style'); s.id = 'babel-style'; s.textContent = \(cssLiteral);
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        let endScript = """
        (function(){
          var head = document.head || document.documentElement;
          var style = document.getElementById('babel-style');
          if (style && document.head && style.parentNode !== document.head) { document.head.appendChild(style); }
          if (!document.querySelector('meta[name=viewport]')) {
            var m = document.createElement('meta'); m.name = 'viewport';
            m.content = 'width=device-width, initial-scale=1, viewport-fit=cover'; head.appendChild(m);
          }
          window.babelSetCSS = function(c){ var s = document.getElementById('babel-style'); if (s) s.textContent = c; };
          window.babelRestore = function(f){
            var h = document.documentElement.scrollHeight - window.innerHeight;
            window.scrollTo(0, Math.max(0, h * f));
          };
          var post = function(m){ window.webkit.messageHandlers.babel.postMessage(m); };
          var timer = null;
          window.addEventListener('scroll', function(){
            clearTimeout(timer);
            timer = setTimeout(function(){
              var h = document.documentElement.scrollHeight - window.innerHeight;
              post({ type: 'progress', value: h > 0 ? window.scrollY / h : 1 });
            }, 120);
          }, { passive: true });
          document.addEventListener('click', function(e){
            if (e.target.closest('a, button, input, select, textarea')) return;
            if ((window.getSelection() + '').length > 0) return;
            post({ type: 'tap' });
          });
          if (\(hasNext ? "true" : "false") && document.body) {
            var end = document.createElement('div'); end.id = 'babel-end';
            var b = document.createElement('button'); b.id = 'babel-next'; b.textContent = \(Self.jsString(String(localized: "Nächstes Kapitel →")));
            b.addEventListener('click', function(ev){ ev.stopPropagation(); post({ type: 'next' }); });
            end.appendChild(b); document.body.appendChild(end);
          }
        })();
        """
        return [WKUserScript(source: startScript, injectionTime: .atDocumentStart, forMainFrameOnly: true),
                WKUserScript(source: endScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)]
    }

    func applyCSS(_ newCSS: String) {
        css = newCSS
        pager?.applyCSS()
    }

    /// Interner EPUB-Link → Index des passenden Kapitels.
    func chapterIndex(forInternal url: URL) -> Int? {
        let base = ContentStore.bookFolder(for: story).resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        let relative = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return story.spinePaths.firstIndex(of: relative)
    }

    func save() {
        story.chapterProgress = progress
        try? story.modelContext?.save()
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.font") private var fontID = "newyork"
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.6
    @AppStorage("reader.margin") private var margin = 22.0
    @AppStorage("reader.justify") private var justify = false
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 0.9

    @State private var model: ReaderModel
    @ObservedObject private var fetcher = WebFetcher.shared
    @State private var showSettings = false
    @State private var showChapters = false
    @State private var showDetail = false

    init(story: Story) {
        _model = State(initialValue: ReaderModel(story: story))
    }

    private var resolvedTheme: ReaderTheme { theme.resolved(colorScheme) }

    private var style: ReaderStyle {
        ReaderStyle(theme: resolvedTheme, font: ReaderFont.find(fontID), fontSize: fontSize,
                    lineHeight: lineHeight, margin: margin, justify: justify, paragraphSpacing: paragraphSpacing)
    }

    var body: some View {
        ZStack {
            resolvedTheme.swiftUIBackground.ignoresSafeArea()

            ReaderPager(model: model, css: style.css, background: resolvedTheme.swiftUIBackground)
                .ignoresSafeArea()

            if model.isLoading {
                ProgressView()
                    .padding(18)
                    .glassEffect(.regular, in: .circle)
            }

            if let error = model.error {
                ErrorBanner(message: error) { model.retry() }
            }

            if model.showChrome {
                VStack {
                    topBar
                    Spacer()
                    if model.isAtEnd && model.story.inLibrary && model.story.status != .finished {
                        Button("Als gelesen markieren", systemImage: "checkmark.circle") {
                            model.story.status = .finished
                            try? model.story.modelContext?.save()
                        }
                        .buttonStyle(.glassProminent)
                        .padding(.bottom, 6)
                    }
                    bottomBar
                }
                .padding(.horizontal, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .preferredColorScheme(theme == .system ? nil : resolvedTheme.colorScheme)
        .statusBarHidden(!model.showChrome)
        .persistentSystemOverlays(model.showChrome ? .automatic : .hidden)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form { ReaderSettingsControls() }
                    .navigationTitle("Darstellung")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig", systemImage: "checkmark") { showSettings = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $fetcher.needsUserInteraction) {
            ChallengeSheet()
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                StoryDetailView(story: model.story)
                    .babelDestinations()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Zurück zum Text", systemImage: "book") { showDetail = false }
                        }
                    }
            }
            // „Lesen“ oder ein Kapitel auf der Storyseite springt im offenen Reader dorthin.
            .environment(\.readerJump, ReaderJump { chapter in
                showDetail = false
                if let chapter { model.jump(to: chapter) }
            })
        }
        .onChange(of: style.css) { _, css in model.applyCSS(css) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.save() } }
        .task { model.start() }
        .onDisappear { model.save() }
    }

    // MARK: - Leisten (Liquid Glass)

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    model.save()
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Schließen")

                Button {
                    model.save()
                    showDetail = true
                } label: {
                    VStack(spacing: 1) {
                        Text(model.story.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(model.chapterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("Zur Storyseite")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "textformat.size").font(.body.weight(.semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Darstellung")
            }
        }
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Button { model.previous() } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!model.hasPrevious)
                .accessibilityLabel("Vorheriges Kapitel")

                Button { showChapters = true } label: {
                    VStack(spacing: 5) {
                        Text("Kapitel \(model.chapterIndex + 1) von \(model.chapterCount)")
                            .font(.caption.weight(.medium))
                        ProgressView(value: model.progress).tint(model.story.source.tint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button { model.next() } label: {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!model.hasNext)
                .accessibilityLabel("Nächstes Kapitel")
            }
        }
        .padding(.bottom, 6)
    }
}

struct ChapterListSheet: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(0..<model.chapterCount, id: \.self) { i in
                    Button {
                        dismiss()
                        model.jump(to: i)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(i + 1)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                            Text(model.story.title(ofChapter: i)).lineLimit(2)
                            Spacer()
                            if i == model.chapterIndex {
                                Image(systemName: "bookmark.fill").foregroundStyle(model.story.source.tint)
                            } else if model.story.source.isWebFiction && !ContentStore.hasChapter(model.story, i) {
                                Image(systemName: "icloud").foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .id(i)
                }
                .onAppear { proxy.scrollTo(model.chapterIndex, anchor: .center) }
            }
            .navigationTitle("Kapitel")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Verhindert einen Retain-Zyklus zwischen WKUserContentController und Coordinator.
@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Aus dem Reader geöffnete Storyseite: „Lesen“/Kapitel springt im offenen Reader, statt ihn neu zu öffnen.
struct ReaderJump {
    let jump: (Int?) -> Void
    init(_ jump: @escaping (Int?) -> Void) { self.jump = jump }
}

private struct ReaderJumpKey: EnvironmentKey {
    static let defaultValue: ReaderJump? = nil
}

extension EnvironmentValues {
    var readerJump: ReaderJump? {
        get { self[ReaderJumpKey.self] }
        set { self[ReaderJumpKey.self] = newValue }
    }
}
