import UIKit
import WebKit

/// Buch-Modus: Seiten blättern mit der Umblätter-Animation von iOS (`UIPageViewController`, `.pageCurl`).
///
/// Jedes Kapitel bleibt ein WKWebView mit Spalten in Bildschirmbreite (`ChapterPageController`). Geblättert werden
/// **Bilder** der Seiten: Im Ruhezustand liegt der echte WebView oben (Markieren, Links, Vorlese-Markierung gehen
/// wie immer), beim Blättern kommt die Blätteransicht mit den Bildern nach vorn. Nach jedem Blättern werden die
/// Nachbarseiten neu aufgenommen – dafür scrollt der WebView kurz verdeckt unter dem Bild der aktuellen Seite.
@MainActor
final class BookPagerController: UIViewController, ReaderPaging, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    struct Key: Hashable {
        var chapter: Int
        /// `Key.last` = letzte Seite eines Kapitels, dessen Seitenzahl noch nicht feststeht.
        var page: Int
        static let last = -1
    }

    private let model: ReaderModel
    private var background: UIColor
    private let pageController = UIPageViewController(
        transitionStyle: .pageCurl, navigationOrientation: .horizontal,
        options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])

    private var chapters: [Int: ChapterPageController] = [:]
    private var counts: [Int: Int] = [:]
    private var snapshots: [Key: UIImage] = [:]
    private let leaves = NSHashTable<BookLeaf>.weakObjects()
    private var current = Key(chapter: 0, page: 0)
    /// Zählt jeden Seiten- oder Kapitelwechsel: Ältere Aufnahmen brechen ab, statt dazwischenzufunken.
    private var generation = 0
    private var isAnimating = false
    private var refreshTask: Task<Void, Never>?
    private var lastSize: CGSize = .zero

    init(model: ReaderModel, background: UIColor) {
        self.model = model
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        pageController.dataSource = self
        pageController.delegate = self
        pageController.isDoubleSided = false
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageController.view.backgroundColor = background
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        // Die eigenen Gesten der Blätteransicht bleiben aus: Im Ruhezustand liegt der WebView darüber, und über ihm
        // griffen sie im Test nur unzuverlässig (Tippen am Rand gar nicht, Ziehen nur bei schnellem Wischen).
        // Stattdessen: Wischen erkennt eine eigene Geste, Tippen am Rand meldet das Skript der Seite.
        for gesture in pageController.gestureRecognizers { gesture.isEnabled = false }
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swipe.delegate = self
        swipe.cancelsTouchesInView = false
        view.addGestureRecognizer(swipe)
        pageController.setViewControllers([leaf(Key(chapter: model.chapterIndex, page: 0))], direction: .forward, animated: false)
        // Nicht während SwiftUI die Ansicht aufbaut den beobachteten Zustand ändern.
        DispatchQueue.main.async { [self] in
            open(model.chapterIndex, restore: model.initialRestore, anchor: model.initialAnchor, replacePosition: false)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else { return }
        let first = lastSize == .zero
        lastSize = view.bounds.size
        if !first { scheduleRefresh() }
    }

    // MARK: Kapitel

    private func chapter(_ index: Int, restore: Double = 0, anchor: Double? = nil) -> ChapterPageController {
        if let existing = chapters[index] { return existing }
        let controller = ChapterPageController(index: index, model: model, restore: restore, anchor: anchor, background: background)
        chapters[index] = controller
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Zuunterst: Nachbarkapitel laden verdeckt vor und liefern die Bilder für das Blättern über die Kapitelgrenze.
        view.insertSubview(controller.view, at: 0)
        controller.didMove(toParent: self)
        return controller
    }

    /// Nur das aktuelle Kapitel und seine Nachbarn behalten.
    private func prune(around index: Int) {
        for (i, controller) in chapters where abs(i - index) > 1 {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            chapters[i] = nil
            counts[i] = nil
        }
        snapshots = snapshots.filter { abs($0.key.chapter - index) <= 1 }
    }

    private func waitUntilReady(_ controller: ChapterPageController, generation gen: Int) async -> Bool {
        while !controller.isReady {
            if controller.errorText != nil || gen != generation { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return gen == generation
    }

    private func pageInfo(_ controller: ChapterPageController) async -> (page: Int, count: Int) {
        let result = try? await controller.webView.evaluateJavaScript("window.babelPageInfo ? window.babelPageInfo() : [0, 1]")
        let values = (result as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        guard values.count == 2 else { return (0, 1) }
        return (max(0, min(values[0], values[1] - 1)), max(values[1], 1))
    }

    /// Kapitel öffnen (Start, Kapitelliste, Chevrons): sofort zeigen, Seitenbilder kommen, sobald es geladen ist.
    private func open(_ index: Int, restore: Double?, anchor: Double?, replacePosition: Bool) {
        generation += 1
        let gen = generation
        prune(around: index)
        let controller = chapter(index, restore: restore ?? 0, anchor: anchor)
        if replacePosition, let restore { controller.jump(to: restore) }
        current = Key(chapter: index, page: 0)
        view.bringSubviewToFront(controller.view)
        model.didShow(index, progress: controller.progress, anchor: controller.anchor, loading: controller.isWaiting, error: controller.errorText)
        Task {
            guard await waitUntilReady(controller, generation: gen) else { return }
            let info = await pageInfo(controller)
            guard gen == generation else { return }
            counts[index] = info.count
            current = Key(chapter: index, page: info.page)
            // Der WebView liegt oben und zeigt die Seite schon – sein Bild wird das Blatt darunter.
            snapshots[current] = await snapshot(controller)
            guard gen == generation else { return }
            pageController.setViewControllers([leaf(current)], direction: .forward, animated: false)
            preloadNeighbors(gen)
            await captureNeighbors(gen)
        }
    }

    private func preloadNeighbors(_ gen: Int) {
        let index = current.chapter
        for n in [index + 1, index - 1] where n >= 0 && n < model.chapterCount {
            // Das vorige Kapitel steht auf seiner letzten Seite bereit.
            let controller = chapter(n, restore: n < index ? 1 : 0)
            guard counts[n] == nil else { continue }
            Task {
                guard await waitUntilReady(controller, generation: gen) else { return }
                let info = await pageInfo(controller)
                guard gen == generation else { return }
                counts[n] = info.count
                // An der Kapitelgrenze fehlt bis jetzt das Bild der Nachbarseite.
                let atBoundary = current.chapter == index && (n > index ? current.page + 1 >= (counts[index] ?? 1) : current.page == 0)
                if atBoundary, !isAnimating { await captureNeighbors(gen) }
            }
        }
    }

    // MARK: Seitenbilder

    private func snapshot(_ controller: ChapterPageController) async -> UIImage? {
        try? await controller.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
    }

    private func setPage(_ page: Int, in controller: ChapterPageController) {
        controller.webView.scrollView.setContentOffset(CGPoint(x: CGFloat(page) * view.bounds.width, y: 0), animated: false)
    }

    private func capture(_ controller: ChapterPageController, page: Int) async -> UIImage? {
        setPage(page, in: controller)
        // Dem WebView einen Moment geben, die Stelle zu zeichnen – sonst zeigt das Bild noch die alte Seite.
        try? await Task.sleep(for: .milliseconds(50))
        return await snapshot(controller)
    }

    private func store(_ image: UIImage?, for key: Key) {
        guard let image else { return }
        snapshots[key] = image
        for leaf in leaves.allObjects where leaf.key == key { leaf.show(image) }
    }

    /// Bilder der Seite davor und danach aufnehmen. Der WebView scrollt dafür verdeckt unter dem Blatt der aktuellen
    /// Seite und kommt danach wieder nach vorn.
    private func captureNeighbors(_ gen: Int) async {
        guard gen == generation, let controller = chapters[current.chapter], controller.isReady else { return }
        let c = current.chapter, p = current.page, n = counts[c] ?? 1
        view.bringSubviewToFront(pageController.view)

        if p + 1 < n {
            store(await capture(controller, page: p + 1), for: Key(chapter: c, page: p + 1))
        } else if let next = chapters[c + 1], next.isReady, counts[c + 1] != nil {
            store(await capture(next, page: 0), for: Key(chapter: c + 1, page: 0))
        }
        guard gen == generation else { return }
        if p > 0 {
            store(await capture(controller, page: p - 1), for: Key(chapter: c, page: p - 1))
        } else if let previous = chapters[c - 1], previous.isReady, let count = counts[c - 1] {
            let image = await capture(previous, page: count - 1)
            store(image, for: Key(chapter: c - 1, page: count - 1))
            store(image, for: Key(chapter: c - 1, page: Key.last))
        }
        guard gen == generation else { return }
        setPage(p, in: controller)
        try? await Task.sleep(for: .milliseconds(50))
        guard gen == generation, !isAnimating else { return }
        view.bringSubviewToFront(controller.view)
        snapshots = snapshots.filter { key, _ in
            key.chapter != c || key.page == Key.last || abs(key.page - p) <= 1
        }
    }

    /// Nach Schrift-, Farb- oder Größenänderungen stimmen Seitenzahl und Bilder nicht mehr: neu zählen und aufnehmen.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.isAnimating else { return }
            await self.refresh()
        }
    }

    private func refresh() async {
        guard let controller = chapters[current.chapter], controller.isReady else { return }
        generation += 1
        let gen = generation
        view.bringSubviewToFront(controller.view)
        for (index, other) in chapters where other.isReady {
            let info = await pageInfo(other)
            guard gen == generation else { return }
            counts[index] = info.count
            if index == current.chapter { current.page = info.page }
        }
        snapshots = [:]
        snapshots[current] = await snapshot(controller)
        guard gen == generation else { return }
        pageController.setViewControllers([leaf(current)], direction: .forward, animated: false)
        await captureNeighbors(gen)
    }

    // MARK: Blätter

    private func leaf(_ key: Key) -> BookLeaf {
        let leaf = BookLeaf(key: key, background: background)
        if let image = snapshots[key] { leaf.show(image) }
        leaves.add(leaf)
        return leaf
    }

    private func resolved(_ key: Key) -> Key? {
        guard key.page == Key.last else { return key }
        guard let count = counts[key.chapter] else { return nil }
        return Key(chapter: key.chapter, page: count - 1)
    }

    private func key(after leaf: BookLeaf) -> Key? {
        guard let key = resolved(leaf.key), let count = counts[key.chapter] else { return nil }
        if key.page + 1 < count { return Key(chapter: key.chapter, page: key.page + 1) }
        return key.chapter + 1 < model.chapterCount ? Key(chapter: key.chapter + 1, page: 0) : nil
    }

    private func key(before leaf: BookLeaf) -> Key? {
        guard let key = resolved(leaf.key) else { return nil }
        if key.page > 0 { return Key(chapter: key.chapter, page: key.page - 1) }
        guard key.chapter > 0 else { return nil }
        if let count = counts[key.chapter - 1] { return Key(chapter: key.chapter - 1, page: count - 1) }
        return Key(chapter: key.chapter - 1, page: Key.last)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let leaf = vc as? BookLeaf, let key = key(before: leaf) else { return nil }
        return self.leaf(key)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let leaf = vc as? BookLeaf, let key = key(after: leaf) else { return nil }
        return self.leaf(key)
    }

    func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
        // Ab jetzt blättern die Bilder; laufende Aufnahmen brechen ab.
        generation += 1
        isAnimating = true
        view.bringSubviewToFront(pageController.view)
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        isAnimating = false
        guard let leaf = pvc.viewControllers?.first as? BookLeaf else { return }
        if completed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { await settle(on: leaf) }
    }

    /// Die Blätteransicht steht auf einem Blatt: den echten WebView dorthin stellen und wieder nach vorn holen.
    private func settle(on leaf: BookLeaf) async {
        generation += 1
        let gen = generation
        var key = leaf.key
        let controller = chapter(key.chapter, restore: key.page == Key.last ? 1 : 0)
        if key.chapter != current.chapter {
            prune(around: key.chapter)
            current = Key(chapter: key.chapter, page: max(key.page, 0))
            model.didShow(key.chapter, progress: controller.progress, anchor: controller.anchor,
                          loading: controller.isWaiting, error: controller.errorText)
            if !controller.isReady {
                // Noch nicht geladen (kommt erst aus dem Netz): den WebView mit Ladesymbol zeigen.
                view.bringSubviewToFront(controller.view)
                guard await waitUntilReady(controller, generation: gen) else { return }
            }
        }
        if counts[key.chapter] == nil { counts[key.chapter] = await pageInfo(controller).count }
        guard gen == generation else { return }
        if let exact = resolved(key) { key = exact }
        key.page = max(0, min(key.page, (counts[key.chapter] ?? 1) - 1))
        leaf.key = key
        current = key
        setPage(key.page, in: controller)
        if snapshots[key] == nil {
            // Schnell hintereinander geblättert: Das Blatt hat noch kein Bild.
            try? await Task.sleep(for: .milliseconds(50))
            store(await snapshot(controller), for: key)
            guard gen == generation else { return }
        }
        preloadNeighbors(gen)
        await captureNeighbors(gen)
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let move = pan.translation(in: view), speed = pan.velocity(in: view)
        // Waagerecht und deutlich: ein Stück gezogen oder kurz geschnippt.
        guard abs(move.x) > abs(move.y) * 1.5, abs(move.x) > 45 || abs(speed.x) > 500 else { return }
        turn(move.x < 0 ? 1 : -1)
    }

    /// Neben den Gesten des WebViews (Markieren, Links) mitlaufen, statt sie zu verdrängen.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: ReaderPaging

    func show(_ index: Int, restore: Double?) {
        guard index >= 0, index < model.chapterCount else { return }
        open(index, restore: restore, anchor: nil, replacePosition: true)
    }

    func show(_ index: Int, anchor: Double) {
        guard index >= 0, index < model.chapterCount else { return }
        if let existing = chapters[index] {
            existing.jump(toAnchor: anchor)
            open(index, restore: nil, anchor: anchor, replacePosition: false)
        } else {
            open(index, restore: 0, anchor: anchor, replacePosition: false)
        }
    }

    func turn(_ direction: Int) {
        guard !isAnimating, let leaf = pageController.viewControllers?.first as? BookLeaf,
              let key = direction > 0 ? key(after: leaf) : key(before: leaf) else { return }
        generation += 1
        isAnimating = true
        view.bringSubviewToFront(pageController.view)
        let target = self.leaf(key)
        let animated = !UIAccessibility.isReduceMotionEnabled
        if animated { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        pageController.setViewControllers([target], direction: direction > 0 ? .forward : .reverse, animated: animated) { [weak self] _ in
            Task { @MainActor in
                self?.isAnimating = false
                await self?.settle(on: target)
            }
        }
    }

    /// Vorlesen: Der gesprochene Absatz liegt auf einer anderen Seite.
    func turn(toPage page: Int, chapter: Int) {
        guard chapter == current.chapter, page != current.page, !isAnimating else { return }
        if abs(page - current.page) == 1 {
            turn(page > current.page ? 1 : -1)
        } else if let controller = chapters[chapter] {
            setPage(page, in: controller)
            scheduleRefresh()
        }
    }

    func scrollPage(_ direction: Int) { turn(direction) }

    func layoutChanged(chapter: Int) {
        guard chapters[chapter] != nil else { return }
        scheduleRefresh()
    }

    func reloadCurrent() {
        let index = current.chapter
        chapters[index]?.load()
        open(index, restore: nil, anchor: nil, replacePosition: false)
    }

    func applySpeech() {
        for controller in chapters.values { controller.applySpeech() }
    }

    func applyMarks() {
        for controller in chapters.values { controller.applyMarks() }
        // Die Seitenbilder zeigen die Markierung sonst erst nach dem nächsten Blättern.
        scheduleRefresh()
    }

    func firstVisibleParagraph(_ completion: @escaping (Int) -> Void) {
        guard let controller = chapters[current.chapter], controller.isReady else { completion(0); return }
        controller.firstVisibleParagraph(completion)
    }

    func applyCSS() {
        for controller in chapters.values { controller.applyCSS() }
        scheduleRefresh()
    }

    func setBackground(_ color: UIColor) {
        guard color != background else { return }
        background = color
        view.backgroundColor = color
        pageController.view.backgroundColor = color
        for controller in chapters.values { controller.setBackground(color) }
        for leaf in leaves.allObjects { leaf.view.backgroundColor = color }
        scheduleRefresh()
    }
}

/// Ein Blatt der Blätteransicht: das Bild einer Seite.
final class BookLeaf: UIViewController {
    var key: BookPagerController.Key
    private let background: UIColor
    private let imageView = UIImageView()

    init(key: BookPagerController.Key, background: UIColor) {
        self.key = key
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        view.addSubview(imageView)
    }

    func show(_ image: UIImage) {
        loadViewIfNeeded()
        imageView.image = image
    }
}
