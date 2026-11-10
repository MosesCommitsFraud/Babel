import SwiftUI
import WebKit

/// Kapitel nebeneinander wie Seiten: Wischen zieht das Nachbarkapitel mit dem Finger herein.
/// Die Nachbarn (vorheriges und nächstes Kapitel) werden vorab geladen und bleiben im Speicher,
/// so gibt es beim Vor- und Zurückwischen weder Ladesymbol noch Neuladen.
struct ReaderPager: UIViewControllerRepresentable {
    let model: ReaderModel
    let css: String
    let background: Color
    var paged = false
    /// Buch-Modus: Umblättern mit Animation statt Schieben.
    var curl = false

    func makeCoordinator() -> ReaderPagerCoordinator { ReaderPagerCoordinator(model: model) }

    func makeUIViewController(context: Context) -> UIViewController {
        // Beim Wechsel des Modus wird die Ansicht neu gebaut – an der Stelle weiter, an der gerade gelesen wird.
        if model.hadPager {
            model.initialRestore = model.progress
            model.initialAnchor = model.anchor
        }
        model.hadPager = true
        model.paged = paged
        model.curl = curl
        model.css = css
        if curl {
            let book = BookPagerController(model: model, background: UIColor(background))
            model.pager = book
            return book
        }
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 20])
        // Seitenweise wischt der Finger durch die Seiten des Kapitels – Kapitelwechsel dann am Rand (siehe ChapterPageController).
        pager.dataSource = model.paged ? nil : context.coordinator
        pager.delegate = context.coordinator
        model.pager = context.coordinator
        context.coordinator.background = UIColor(background)
        context.coordinator.attach(pager)
        return pager
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        if let book = controller as? BookPagerController {
            book.setBackground(UIColor(background))
        } else {
            context.coordinator.setBackground(UIColor(background))
        }
    }
}

/// Was der Reader von der Seitenansicht braucht – egal ob Scrollen/Schieben (`ReaderPagerCoordinator`)
/// oder Buch-Modus (`BookPagerController`).
@MainActor
protocol ReaderPaging: AnyObject {
    /// Zu einem Kapitel wechseln. `restore`: Stelle im Zielkapitel (0…1), z. B. 1 = letzte Seite beim Zurückblättern.
    func show(_ index: Int, restore: Double?)
    /// Zu einem Absatz eines Kapitels wechseln.
    func show(_ index: Int, anchor: Double)
    func reloadCurrent()
    func applySpeech()
    func firstVisibleParagraph(_ completion: @escaping (Int) -> Void)
    /// Eine Bildschirmseite weiter (+1) oder zurück (-1); am Kapitelende weiter zum nächsten Kapitel.
    func scrollPage(_ direction: Int)
    func applyCSS()
    /// Nur Buch-Modus: eine Seite umblättern, zu einer Seite springen, Seitenbilder nach Layout-Änderung erneuern.
    func turn(_ direction: Int)
    func turn(toPage page: Int, chapter: Int)
    func layoutChanged(chapter: Int)
    /// Markierungen auf allen geladenen Kapitelseiten neu zeichnen.
    func applyMarks()
}

extension ReaderPaging {
    func turn(_ direction: Int) {}
    func turn(toPage page: Int, chapter: Int) {}
    func layoutChanged(chapter: Int) {}
}

@MainActor
final class ReaderPagerCoordinator: NSObject, ReaderPaging, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let model: ReaderModel
    var background: UIColor = .systemBackground
    private weak var pager: UIPageViewController?
    private var pages: [Int: ChapterPageController] = [:]
    private var isJumping = false

    init(model: ReaderModel) { self.model = model }

    func attach(_ pager: UIPageViewController) {
        self.pager = pager
        pager.view.backgroundColor = background
        let first = page(model.chapterIndex, restore: model.initialRestore, anchor: model.initialAnchor)
        pager.setViewControllers([first], direction: .forward, animated: false)
        // Nicht während SwiftUI die Ansicht aufbaut den beobachteten Zustand ändern.
        DispatchQueue.main.async { self.becameCurrent(first) }
    }

    private func page(_ index: Int, restore: Double = 0, anchor: Double? = nil) -> ChapterPageController {
        if let existing = pages[index] { return existing }
        let page = ChapterPageController(index: index, model: model, restore: restore, anchor: anchor, background: background)
        pages[index] = page
        return page
    }

    // MARK: Datenquelle

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let current = vc as? ChapterPageController, current.index > 0 else { return nil }
        return page(current.index - 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let current = vc as? ChapterPageController, current.index + 1 < model.chapterCount else { return nil }
        return page(current.index + 1)
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let current = pvc.viewControllers?.first as? ChapterPageController else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        becameCurrent(current)
    }

    // MARK: Navigation

    func show(_ index: Int, anchor: Double) {
        if index == model.chapterIndex {
            pages[index]?.jump(toAnchor: anchor)
        } else {
            // Die Seite neu anlegen, damit sie gleich am Absatz aufgeht.
            pages[index] = nil
            _ = page(index, restore: 0, anchor: anchor)
            show(index, restore: nil)
        }
    }

    /// Zu einem Kapitel blättern (Knöpfe, Kapitelliste, Rand beim seitenweisen Blättern).
    /// `restore`: Stelle im Zielkapitel (0…1), z. B. 1 = letzte Seite beim Zurückblättern.
    func show(_ index: Int, restore: Double?) {
        guard let pager, !isJumping else { return }
        let direction: UIPageViewController.NavigationDirection = index > model.chapterIndex ? .forward : .reverse
        let target = page(index, restore: restore ?? 0)
        if let restore { target.jump(to: restore) }
        // Weit entfernte Sprünge ohne Animation durch fremde Kapitel – nur Nachbarn gleiten herein.
        let animated = abs(index - model.chapterIndex) == 1
        isJumping = true
        pager.setViewControllers([target], direction: direction, animated: animated) { [weak self, weak pager] _ in
            // UIPageViewController merkt sich nach animierten Sprüngen sonst die alten Nachbarn.
            DispatchQueue.main.async {
                pager?.setViewControllers([target], direction: direction, animated: false)
                self?.isJumping = false
                self?.becameCurrent(target)
            }
        }
    }

    func reloadCurrent() {
        pages[model.chapterIndex]?.load()
    }

    /// Vorlese-Markierung auf alle geladenen Kapitelseiten übertragen.
    func applySpeech() {
        for page in pages.values { page.applySpeech() }
    }

    func applyMarks() {
        for page in pages.values { page.applyMarks() }
    }

    /// Erster sichtbarer Absatz des aktuellen Kapitels (Start fürs Vorlesen).
    func firstVisibleParagraph(_ completion: @escaping (Int) -> Void) {
        guard let page = pages[model.chapterIndex], page.isReady else { completion(0); return }
        page.firstVisibleParagraph(completion)
    }

    /// Eine Bildschirmseite weiter (+1) oder zurück (-1); am Kapitelende weiter zum nächsten Kapitel.
    func scrollPage(_ direction: Int) {
        guard let page = pages[model.chapterIndex], page.isReady else { return }
        page.scrollPage(direction) { [weak self] atEnd in
            if atEnd { self?.model.next() }
        }
    }

    private func becameCurrent(_ page: ChapterPageController) {
        model.didShow(page.index, progress: page.progress, anchor: page.anchor, loading: page.isWaiting, error: page.errorText)
        // Nur aktuelles Kapitel ± 2 im Speicher halten.
        pages = pages.filter { abs($0.key - page.index) <= 2 }
        if page.isReady {
            preloadNeighbors(of: page.index)
        } else {
            // Erst nach dem aktuellen Kapitel laden – AO3/EPUB holen beim ersten Mal alles auf einmal.
            page.onReady = { [weak self] in
                guard let self, self.model.chapterIndex == page.index else { return }
                self.preloadNeighbors(of: page.index)
            }
        }
    }

    private func preloadNeighbors(of index: Int) {
        for n in [index + 1, index - 1] where n >= 0 && n < model.chapterCount {
            page(n).loadViewIfNeeded()
        }
    }

    // MARK: Darstellung

    func applyCSS() {
        for page in pages.values { page.applyCSS() }
    }

    func setBackground(_ color: UIColor) {
        guard color != background else { return }
        background = color
        pager?.view.backgroundColor = color
        for page in pages.values { page.setBackground(color) }
    }
}

/// Eine Kapitelseite mit eigenem WKWebView.
@MainActor
final class ChapterPageController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    let index: Int
    let model: ReaderModel
    private var restore: Double
    /// Absatz-Anker der Stelle; hat Vorrang vor dem Bruchteil `restore`.
    private(set) var anchor: Double?
    private var background: UIColor
    private(set) var webView: WKWebView!
    private var loadTask: Task<Void, Never>?

    private(set) var progress: Double
    private(set) var isReady = false
    private(set) var isWaiting = false
    private(set) var errorText: String?
    var onReady: (() -> Void)?

    init(index: Int, model: ReaderModel, restore: Double, anchor: Double?, background: UIColor) {
        self.index = index
        self.model = model
        self.restore = restore
        self.anchor = anchor
        self.progress = restore
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "babel")
        for script in model.scripts(for: index) { config.userContentController.addUserScript(script) }
        config.dataDetectorTypes = []
        let view = ReaderWebView(frame: .zero, configuration: config)
        if model.marksEnabled {
            view.onMark = { [weak self] withNote in self?.markSelection(withNote: withNote) }
        }
        view.navigationDelegate = self
        // Hell/Dunkel des WebViews folgt dem Lesethema, nicht dem Gerät – danach richten sich `prefers-color-scheme`
        // in den Stylesheets der Bücher und die Standardfarben von WebKit.
        view.overrideUserInterfaceStyle = Self.style(for: background)
        view.isOpaque = false
        view.backgroundColor = background
        view.scrollView.backgroundColor = background
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsHorizontalScrollIndicator = false
        // Nur senkrecht scrollen – waagerecht blättert der Pager.
        view.scrollView.alwaysBounceHorizontal = false
        view.scrollView.isDirectionalLockEnabled = true
        view.allowsLinkPreview = false
        if model.paged && model.curl {
            // Buch-Modus: Geblättert wird über die Seitenbilder des `BookPagerController`, nicht durch Scrollen.
            view.scrollView.isScrollEnabled = false
            view.scrollView.showsVerticalScrollIndicator = false
        } else if model.paged {
            view.scrollView.isPagingEnabled = true
            view.scrollView.alwaysBounceVertical = false
            view.scrollView.showsVerticalScrollIndicator = false
            view.scrollView.alwaysBounceHorizontal = true
            view.scrollView.panGestureRecognizer.addTarget(self, action: #selector(edgePan(_:)))
        }
        webView = view
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()
    }

    func load() {
        loadTask?.cancel()
        isReady = false
        errorText = nil
        let story = model.story
        isWaiting = story.source.isWebFiction ? !ContentStore.hasChapter(story, index) : !ContentStore.isBookInstalled(story)
        loadTask = Task { [weak self] in
            guard let self else { return }
            self.model.pageState(self.index, loading: self.isWaiting, error: nil)
            do {
                let url = try await LibraryManager.shared.ensureChapter(story, index: self.index)
                guard !Task.isCancelled else { return }
                self.webView.loadFileURL(url, allowingReadAccessTo: ContentStore.folder(for: story))
            } catch {
                guard !Task.isCancelled else { return }
                self.isWaiting = false
                self.errorText = error.localizedDescription
                self.model.pageState(self.index, loading: false, error: self.errorText)
            }
        }
    }

    func applyCSS() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in model.scripts(for: index) { controller.addUserScript(script) }
        webView.evaluateJavaScript("window.babelSetCSS && window.babelSetCSS(\(ReaderModel.jsString(model.css))); true",
                                   completionHandler: nil)
    }

    func setBackground(_ color: UIColor) {
        background = color
        guard isViewLoaded else { return }
        webView.overrideUserInterfaceStyle = Self.style(for: color)
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
    }

    private static func style(for background: UIColor) -> UIUserInterfaceStyle {
        var white: CGFloat = 0, alpha: CGFloat = 0
        background.getWhite(&white, alpha: &alpha)
        return white < 0.5 ? .dark : .light
    }

    /// Eine Bildschirmseite weiter/zurück (mit etwas Überlappung); meldet, ob es schon am Kapitelende stand.
    func scrollPage(_ direction: Int, atEnd: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("window.babelPage ? window.babelPage(\(direction)) : 'ok'") { result, _ in
            atEnd(result as? String == "end")
        }
    }

    func applySpeech() {
        guard isReady else { return }
        let active = model.speechActive ? "true" : "false"
        let js: String
        if let s = model.speech, s.chapter == index {
            js = "window.babelReadAloud = \(active); window.babelSpeak && window.babelSpeak(\(s.paragraph), \(ReaderModel.jsString(s.sentence ?? "")), true); true"
        } else {
            js = "window.babelReadAloud = \(active); window.babelSpeak && window.babelSpeak(-1, '', false); true"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func applyMarks() {
        guard isReady, model.marksEnabled else { return }
        webView.evaluateJavaScript("window.babelSetMarks && window.babelSetMarks(\(model.marksJSON(chapter: index))); true", completionHandler: nil)
    }

    /// Auswahl markieren (aus dem Menü über dem markierten Text), auf Wunsch gleich mit Notiz.
    private func markSelection(withNote: Bool) {
        webView.evaluateJavaScript("window.babelSelectionParts ? window.babelSelectionParts() : []") { [weak self] result, _ in
            guard let self, let parts = result as? [[String: Any]], !parts.isEmpty else { return }
            let added = self.model.addMarks(parts, chapter: self.index)
            if withNote, !added.isEmpty {
                self.model.openedMarks = ReaderModel.MarkSelection(highlights: added, chapter: self.index)
            }
        }
    }

    func firstVisibleParagraph(_ completion: @escaping (Int) -> Void) {
        webView.evaluateJavaScript("window.babelFirstVisible ? window.babelFirstVisible() : 0") { result, _ in
            completion((result as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Stelle setzen – sofort, falls schon geladen, sonst beim Laden.
    func jump(to fraction: Double) {
        restore = fraction
        progress = fraction
        anchor = nil
        if isReady { scroll(to: fraction, anchor: nil) }
    }

    func jump(toAnchor value: Double) {
        anchor = value
        if isReady { scroll(to: restore, anchor: value) }
    }

    /// Zum Absatz-Anker, sonst (oder wenn es den Absatz nicht gibt) zum Bruchteil.
    private func scroll(to fraction: Double, anchor: Double?) {
        let byAnchor = anchor.map { "(window.babelRestoreAnchor && window.babelRestoreAnchor(\($0))) || " } ?? ""
        webView.evaluateJavaScript("\(byAnchor)(window.babelRestore && window.babelRestore(\(fraction))); true", completionHandler: nil)
    }

    /// Seitenweise: Wischen über die erste/letzte Seite hinaus wechselt das Kapitel.
    private var panStart: CGFloat = 0

    @objc private func edgePan(_ pan: UIPanGestureRecognizer) {
        let scroll = webView.scrollView
        let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
        switch pan.state {
        case .began:
            panStart = scroll.contentOffset.x
        case .ended:
            let dx = pan.translation(in: scroll).x
            if panStart >= maxX - 2 && dx < -50 { model.next() }
            else if panStart <= 2 && dx > 50 { model.previous(toEnd: true) }
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let target = restore
        let targetAnchor = anchor
        scroll(to: target, anchor: targetAnchor)
        // Sofort bereit: Die Nachbarkapitel laden gleich vor, statt eine feste Frist abzuwarten.
        isReady = true
        isWaiting = false
        model.pageState(index, loading: false, error: nil)
        applySpeech()
        applyMarks()
        onReady?()
        guard target > 0 || targetAnchor != nil else { return }
        Task { [weak self] in
            // Bilder können die Höhe später ändern – noch einmal nachjustieren, solange niemand weitergescrollt hat.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, abs(self.progress - target) < 0.02 else { return }
            self.scroll(to: target, anchor: targetAnchor)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        if url.isFileURL {
            // Sprung innerhalb derselben Datei (Fußnoten) erlauben
            if url.path == webView.url?.path { return .allow }
            if let target = model.chapterIndex(forInternal: url) {
                model.jump(to: target)
                return .cancel
            }
            return .allow
        }
        await UIApplication.shared.open(url)
        return .cancel
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "progress" {
            guard isReady, let value = body["value"] as? Double else { return }
            progress = min(1, max(0, value))
            restore = progress
            anchor = body["anchor"] as? Double
            model.pageProgress(index, progress, anchor: anchor)
        } else {
            model.handle(message: body, from: index)
        }
    }
}

/// WKWebView des Readers: ergänzt das Menü über markiertem Text um „Markieren“ und „Notiz“,
/// wenn Markierungen in den Einstellungen eingeschaltet sind.
final class ReaderWebView: WKWebView {
    /// `true` = gleich mit Notiz. Nicht gesetzt = Markierungen aus, das Menü bleibt wie von iOS.
    var onMark: ((Bool) -> Void)?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let onMark else { return }
        let mark = UIAction(title: String(localized: "Markieren"), image: UIImage(systemName: "highlighter")) { _ in onMark(false) }
        let note = UIAction(title: String(localized: "Notiz"), image: UIImage(systemName: "note.text")) { _ in onMark(true) }
        builder.insertChild(UIMenu(options: .displayInline, children: [mark, note]), atStartOfMenu: .standardEdit)
    }
}
