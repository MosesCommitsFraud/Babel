import SwiftUI
import WebKit

/// Kapitel nebeneinander wie Seiten: Wischen zieht das Nachbarkapitel mit dem Finger herein.
/// Die Nachbarn (vorheriges und nächstes Kapitel) werden vorab geladen und bleiben im Speicher,
/// so gibt es beim Vor- und Zurückwischen weder Ladesymbol noch Neuladen.
struct ReaderPager: UIViewControllerRepresentable {
    let model: ReaderModel
    let css: String
    let background: Color

    func makeCoordinator() -> ReaderPagerCoordinator { ReaderPagerCoordinator(model: model) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 20])
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        model.css = css
        model.pager = context.coordinator
        context.coordinator.background = UIColor(background)
        context.coordinator.attach(pager)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.setBackground(UIColor(background))
    }
}

@MainActor
final class ReaderPagerCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let model: ReaderModel
    var background: UIColor = .systemBackground
    private weak var pager: UIPageViewController?
    private var pages: [Int: ChapterPageController] = [:]
    private var isJumping = false

    init(model: ReaderModel) { self.model = model }

    func attach(_ pager: UIPageViewController) {
        self.pager = pager
        pager.view.backgroundColor = background
        let first = page(model.chapterIndex, restore: model.initialRestore)
        pager.setViewControllers([first], direction: .forward, animated: false)
        // Nicht während SwiftUI die Ansicht aufbaut den beobachteten Zustand ändern.
        DispatchQueue.main.async { self.becameCurrent(first) }
    }

    private func page(_ index: Int, restore: Double = 0) -> ChapterPageController {
        if let existing = pages[index] { return existing }
        let page = ChapterPageController(index: index, model: model, restore: restore, background: background)
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

    /// Zu einem Kapitel blättern (Knöpfe, Kapitelliste, „Nächstes Kapitel“ am Ende).
    func show(_ index: Int) {
        guard let pager, !isJumping else { return }
        let direction: UIPageViewController.NavigationDirection = index > model.chapterIndex ? .forward : .reverse
        let target = page(index)
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

    /// Eine Bildschirmseite weiter (+1) oder zurück (-1); am Kapitelende weiter zum nächsten Kapitel.
    func scrollPage(_ direction: Int) {
        guard let page = pages[model.chapterIndex], page.isReady else { return }
        if direction > 0, model.progress > 0.995 {
            model.next()
        } else {
            page.scrollPage(direction)
        }
    }

    private func becameCurrent(_ page: ChapterPageController) {
        model.didShow(page.index, progress: page.progress, loading: page.isWaiting, error: page.errorText)
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
    private var background: UIColor
    private var webView: WKWebView!
    private var loadTask: Task<Void, Never>?

    private(set) var progress: Double
    private(set) var isReady = false
    private(set) var isWaiting = false
    private(set) var errorText: String?
    var onReady: (() -> Void)?

    init(index: Int, model: ReaderModel, restore: Double, background: UIColor) {
        self.index = index
        self.model = model
        self.restore = restore
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
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = background
        view.scrollView.backgroundColor = background
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsHorizontalScrollIndicator = false
        // Nur senkrecht scrollen – waagerecht blättert der Pager.
        view.scrollView.alwaysBounceHorizontal = false
        view.scrollView.isDirectionalLockEnabled = true
        view.allowsLinkPreview = false
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
        isWaiting = story.source.isWebFiction ? !ContentStore.hasChapter(story, index) : story.spinePaths.isEmpty
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
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
    }

    func scrollPage(_ direction: Int) {
        // Etwas Überlappung, damit die letzte Zeile oben wieder zu sehen ist.
        webView.evaluateJavaScript("window.scrollBy({ top: \(direction) * window.innerHeight * 0.85, behavior: 'smooth' }); true",
                                   completionHandler: nil)
    }

    private func scroll(to fraction: Double) {
        webView.evaluateJavaScript("window.babelRestore && window.babelRestore(\(fraction)); true", completionHandler: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let target = restore
        scroll(to: target)
        Task { [weak self] in
            // Bilder können die Höhe später ändern – noch einmal nachjustieren.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            if target > 0 { self.scroll(to: target) }
            self.isReady = true
            self.isWaiting = false
            self.model.pageState(self.index, loading: false, error: nil)
            self.onReady?()
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
            model.pageProgress(index, progress)
        } else {
            model.handle(message: body, from: index)
        }
    }
}
