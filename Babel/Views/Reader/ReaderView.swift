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

    @ObservationIgnored weak var pager: (any ReaderPaging)?
    /// Markierungen und Notizen – nur, wenn in den Einstellungen eingeschaltet.
    @ObservationIgnored let marksEnabled = HighlightSettings.isEnabled
    /// Angetippte Markierung (öffnet Notiz/Löschen) bzw. frisch markierte Stellen, zu denen eine Notiz soll.
    var openedMarks: MarkSelection?

    struct MarkSelection: Identifiable {
        let id = UUID()
        var highlights: [Highlight]
        var chapter: Int
    }

    /// Markierungen eines Kapitels als JSON fürs Seitenskript.
    func marksJSON(chapter: Int) -> String {
        let items = HighlightSettings.all(for: story.key, in: story.modelContext).filter { $0.chapter == chapter }
            .map { ["id": $0.syncID, "p": $0.paragraph, "s": $0.start, "e": $0.end, "n": !$0.note.isEmpty] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Auswahl aus dem Seitenskript speichern: je Absatz eine Markierung.
    @discardableResult
    func addMarks(_ parts: [[String: Any]], chapter: Int) -> [Highlight] {
        guard let context = story.modelContext else { return [] }
        var added: [Highlight] = []
        for part in parts {
            guard let paragraph = part["p"] as? Int, let start = part["s"] as? Int, let end = part["e"] as? Int,
                  let text = part["t"] as? String, end > start else { continue }
            let highlight = Highlight(storyKey: story.key, chapter: chapter, paragraph: paragraph, start: start, end: end, text: text)
            context.insert(highlight)
            added.append(highlight)
        }
        try? context.save()
        pager?.applyMarks()
        return added
    }

    func deleteMarks(_ highlights: [Highlight]) {
        guard let context = story.modelContext else { return }
        for highlight in highlights { context.delete(highlight) }
        try? context.save()
        pager?.applyMarks()
    }

    func marksChanged() {
        try? story.modelContext?.save()
        pager?.applyMarks()
    }

    /// Es gab schon eine Seitenansicht – eine neue (anderer Blättermodus) macht an der aktuellen Stelle weiter.
    @ObservationIgnored var hadPager = false
    @ObservationIgnored var css = ""
    @ObservationIgnored var initialRestore: Double
    /// Absatz-Anker zur Lesestelle – übersteht andere Schriftgrößen und Bildschirme, der Bruchteil allein nicht.
    @ObservationIgnored var initialAnchor: Double?
    @ObservationIgnored var anchor: Double?
    /// Seitenweise blättern (Spalten) statt scrollen.
    @ObservationIgnored var paged = UserDefaults.standard.bool(forKey: ReaderDefaults.pagedKey)
    /// Buch-Modus: Seiten blättern mit Umblätter-Animation (`BookPagerController`). Nur zusammen mit `paged`.
    @ObservationIgnored var curl = UserDefaults.standard.bool(forKey: ReaderDefaults.curlKey)
    @ObservationIgnored private var lastSave = Date.distantPast
    /// Vorlesen: wo gerade gesprochen wird (nur für diese Geschichte) und ob Tippen einen Absatz startet.
    @ObservationIgnored var speech: ReadAloudPlayer.Cursor?
    @ObservationIgnored var speechActive = false
    @ObservationIgnored var onSpeakFrom: ((_ chapter: Int, _ paragraph: Int) -> Void)?

    init(story: Story) {
        self.story = story
        self.chapterIndex = min(story.currentChapter, max(story.knownChapterCount - 1, 0))
        self.progress = story.chapterProgress
        self.initialRestore = story.chapterProgress
        self.initialAnchor = story.currentAnchor
        self.anchor = story.currentAnchor
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

    func next() { guard hasNext else { return }; pager?.show(chapterIndex + 1, restore: nil) }
    /// `toEnd`: beim Zurückblättern über den Kapitelanfang auf der letzten Seite des vorigen Kapitels landen.
    func previous(toEnd: Bool = false) { guard hasPrevious else { return }; pager?.show(chapterIndex - 1, restore: toEnd ? 1 : nil) }

    func jump(to index: Int) {
        guard index >= 0, index < max(chapterCount, 1), index != chapterIndex else { return }
        pager?.show(index, restore: nil)
    }

    /// Zu einem Absatz springen (Markierung aus der Liste) – auch im schon offenen Kapitel.
    func jump(to index: Int, anchor: Double) {
        guard index >= 0, index < max(chapterCount, 1) else { return }
        pager?.show(index, anchor: anchor)
    }

    func retry() {
        error = nil
        pager?.reloadCurrent()
    }

    /// Eine Seite ist zur aktuellen geworden – nach dem Wischen oder einem Sprung.
    func didShow(_ index: Int, progress: Double, anchor: Double?, loading: Bool, error: String?) {
        chapterIndex = index
        self.progress = progress
        self.anchor = anchor
        isLoading = loading
        self.error = error
        story.currentChapter = index
        story.setPosition(progress: progress, anchor: anchor)
        story.lastOpenedAt = .now
        try? story.modelContext?.save()
    }

    func pageState(_ index: Int, loading: Bool, error: String?) {
        guard index == chapterIndex else { return }
        isLoading = loading
        self.error = error
    }

    func pageProgress(_ index: Int, _ value: Double, anchor: Double?) {
        guard index == chapterIndex else { return }
        progress = min(1, max(0, value))
        self.anchor = anchor
        story.setPosition(progress: progress, anchor: anchor)
        // Selten sichern: Jedes Speichern schickt die ganze Zeile an iCloud und weckt die Listen dahinter.
        // Kapitelwechsel, Schließen und der Wechsel in den Hintergrund sichern ohnehin.
        if Date().timeIntervalSince(lastSave) > 30 {
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
        case "previous":
            if index == chapterIndex { previous(toEnd: true) }
        case "turn":
            if index == chapterIndex, let direction = message["dir"] as? Int { pager?.turn(direction) }
        case "speechPage":
            if let page = message["page"] as? Int { pager?.turn(toPage: page, chapter: index) }
        case "layout":
            pager?.layoutChanged(chapter: index)
        case "mark":
            guard let ids = message["ids"] as? [String], !ids.isEmpty else { break }
            let found = HighlightSettings.all(for: story.key, in: story.modelContext).filter { ids.contains($0.syncID) }
            if !found.isEmpty { openedMarks = MarkSelection(highlights: found, chapter: index) }
        case "speakFrom":
            if let paragraph = message["paragraph"] as? Int { onSpeakFrom?(index, paragraph) }
        default:
            break
        }
    }

    // MARK: - WebView-Skripte (pro Kapitelseite)

    func scripts(for index: Int) -> [WKUserScript] {
        let cssLiteral = Self.jsString(css)
        let startScript = """
        (function(){
          var s = document.createElement('style'); s.id = 'babel-style'; s.textContent = \(cssLiteral);
          (document.head || document.documentElement).appendChild(s);
          window.babelPaged = \(paged ? "true" : "false");
          window.babelCurl = \(paged && curl ? "true" : "false");
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
          // Seitenweise: Breite auf ganze Seiten auffüllen – der letzten Spalte fehlt sonst der Rand rechts
          // und sie rastet nicht sauber ein.
          window.babelPaginate = function(){
            if (!window.babelPaged) return;
            var pad = document.getElementById('babel-pagepad');
            if (!pad) {
              pad = document.createElement('div'); pad.id = 'babel-pagepad';
              pad.style.cssText = 'position:absolute;top:0;left:0;width:1px;height:1px;pointer-events:none;';
              document.documentElement.appendChild(pad);
            }
            pad.style.left = '0px';
            var w = window.innerWidth;
            var pages = Math.max(1, Math.ceil((document.documentElement.scrollWidth - 1) / w));
            pad.style.left = (pages * w - 1) + 'px';
            // Buch-Modus: Die App hält Bilder der Seiten vor – ändert sich die Seitenzahl (Bild nachgeladen), neu aufnehmen.
            if (window.babelCurl && window.babelPages !== pages) {
              var first = window.babelPages == null;
              window.babelPages = pages;
              if (!first && window.babelPost) window.babelPost({ type: 'layout' });
            }
          };
          window.babelPageInfo = function(){
            var w = window.innerWidth;
            return [Math.round(window.scrollX / w), Math.max(1, Math.round(document.documentElement.scrollWidth / w))];
          };
          window.babelFraction = function(){
            if (window.babelPaged) {
              var mw = document.documentElement.scrollWidth - window.innerWidth;
              return mw > 0 ? window.scrollX / mw : 1;
            }
            var h = document.documentElement.scrollHeight - window.innerHeight;
            return h > 0 ? window.scrollY / h : 1;
          };
          // Neue Schrift oder Ränder: Der Absatz oben bleibt oben, statt mit dem Umbruch davonzulaufen.
          window.babelSetCSS = function(c){
            var f = window.babelFraction(), a = window.babelAnchor();
            var s = document.getElementById('babel-style'); if (s) s.textContent = c;
            if (window.babelPaged) window.babelPaginate();
            if (a != null) { window.babelRestoreAnchor(a); } else if (window.babelPaged) { window.babelRestore(f); }
          };
          window.babelRestore = function(f){
            if (window.babelPaged) {
              window.babelPaginate();
              var w = window.innerWidth, mw = document.documentElement.scrollWidth - w;
              window.scrollTo(Math.max(0, Math.round(mw * f / w) * w), 0);
              return;
            }
            var h = document.documentElement.scrollHeight - window.innerHeight;
            window.scrollTo(0, Math.max(0, h * f));
          };
          // Eine Seite vor/zurück (Tippen an den Rand, Lautstärketasten). 'end'/'start' am Kapitelrand.
          window.babelTurn = function(dir){
            var w = window.innerWidth, max = document.documentElement.scrollWidth - w;
            var base = (window.babelTurnTarget != null) ? window.babelTurnTarget : window.scrollX;
            var target = Math.round(base / w) * w + dir * w;
            if (target > max + 2) return 'end';
            if (target < -2) return 'start';
            target = Math.max(0, Math.min(max, target));
            window.babelTurnTarget = target;
            var from = window.scrollX, t0 = performance.now(), dur = 240;
            cancelAnimationFrame(window.babelTurnAnim);
            var step = function(t){
              var p = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - p, 3);
              window.scrollTo(from + (target - from) * e, 0);
              if (p < 1) { window.babelTurnAnim = requestAnimationFrame(step); } else { window.babelTurnTarget = null; }
            };
            window.babelTurnAnim = requestAnimationFrame(step);
            return 'ok';
          };
          if (window.babelPaged) {
            window.addEventListener('resize', function(){ var f = window.babelFraction(); window.babelPaginate(); window.babelRestore(f); });
            window.addEventListener('load', function(){ window.babelPaginate(); });
            Array.prototype.forEach.call(document.images, function(img){ img.addEventListener('load', function(){ window.babelPaginate(); }); });
            window.babelPaginate();
          }
          // Seitenweise blättern (Lautstärketasten): kurze eigene Animation, schnelle Drücke addieren sich.
          // Gibt 'end' zurück, wenn es schon am Kapitelende stand.
          window.babelPage = function(dir){
            if (window.babelPaged) { var r = window.babelTurn(dir); return r === 'start' ? 'ok' : r; }
            var max = document.documentElement.scrollHeight - window.innerHeight;
            var base = (window.babelTarget != null) ? window.babelTarget : window.scrollY;
            if (dir > 0 && base >= max - 2) return 'end';
            var target = Math.max(0, Math.min(max, base + dir * window.innerHeight * 0.85));
            window.babelTarget = target;
            var from = window.scrollY, t0 = performance.now(), dur = 160;
            cancelAnimationFrame(window.babelAnim);
            var step = function(t){
              var p = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - p, 3);
              window.scrollTo(0, from + (target - from) * e);
              if (p < 1) { window.babelAnim = requestAnimationFrame(step); } else { window.babelTarget = null; }
            };
            window.babelAnim = requestAnimationFrame(step);
            return 'ok';
          };
          var post = function(m){ window.webkit.messageHandlers.babel.postMessage(m); };
          window.babelPost = post;
          var timer = null;
          window.addEventListener('scroll', function(){
            clearTimeout(timer);
            timer = setTimeout(function(){
              // Solange die Spalten noch nicht stehen, gäbe es „100 %“ – dann nichts melden.
              if (window.babelPaged && document.documentElement.scrollWidth <= window.innerWidth + 1) return;
              var m = { type: 'progress', value: window.babelFraction() }, a = window.babelAnchor();
              if (a != null) m.anchor = a;
              post(m);
            }, 120);
          }, { passive: true });
          // Vorlesen: dieselbe Absatz-Zählung wie ReadAloudPlayer.blocks(from:).
          var blockSel = \(Self.jsString(ReadAloudPlayer.blockSelector));
          window.babelBlocks = function(){
            var list = Array.prototype.filter.call(document.body.querySelectorAll(blockSel), function(e){
              return !e.querySelector(blockSel) && e.textContent.trim().length > 0;
            });
            if (!list.length && document.body.textContent.trim().length) list = [document.body];
            return list;
          };
          // Lesestelle als Absatz: Index des obersten sichtbaren Absatzes + wie weit er schon durchgelesen ist.
          window.babelAnchor = function(){
            // Ganz oben gilt der Kapitelanfang, nicht der erste Absatz (der läge sonst unter der Leiste).
            if (!window.babelPaged && window.scrollY <= 0) return null;
            var list = window.babelBlocks();
            for (var i = 0; i < list.length; i++) {
              var r = list[i].getBoundingClientRect();
              if (window.babelPaged) {
                if (r.right <= 1) continue;
                // Ein Absatz über mehrere Seiten hat je Spalte ein Rechteck.
                var rects = list[i].getClientRects(), k = 0;
                while (k < rects.length - 1 && rects[k].right <= 1) k++;
                return i + Math.min(0.999, rects.length ? k / rects.length : 0);
              }
              if (r.bottom > 0) return i + Math.min(0.999, Math.max(0, r.height > 0 ? -r.top / r.height : 0));
            }
            return null;
          };
          window.babelRestoreAnchor = function(a){
            var list = window.babelBlocks(), i = Math.floor(a), frac = a - i;
            if (i < 0 || i >= list.length) return false;
            if (window.babelPaged) {
              window.babelPaginate();
              var rects = list[i].getClientRects(), w = window.innerWidth;
              if (!rects.length) return false;
              var rect = rects[Math.min(rects.length - 1, Math.floor(frac * rects.length + 0.001))];
              window.scrollTo(Math.max(0, Math.floor((window.scrollX + rect.left + 1) / w) * w), 0);
              return true;
            }
            var r = list[i].getBoundingClientRect();
            window.scrollTo(0, Math.max(0, window.scrollY + r.top + frac * r.height));
            return true;
          };
          // Markierungen: Zeichenbereiche in Absätzen, gezeichnet über CSS Custom Highlights (ändert das HTML nicht).
          var markRanges = [];
          var rangeIn = function(el, start, end){
            var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), pos = 0, r = document.createRange(), open = false;
            while (walker.nextNode()) {
              var n = walker.currentNode, len = n.nodeValue.length;
              if (!open && start < pos + len) { r.setStart(n, Math.max(0, start - pos)); open = true; }
              if (open && end <= pos + len) { r.setEnd(n, Math.max(0, end - pos)); return r; }
              pos += len;
            }
            if (open) { r.setEndAfter(el.lastChild); return r; }
            return null;
          };
          window.babelSetMarks = function(items){
            markRanges = [];
            if (!(window.CSS && CSS.highlights)) return;
            var plain = [], noted = [], list = window.babelBlocks();
            items.forEach(function(m){
              if (m.p < 0 || m.p >= list.length) return;
              var r = rangeIn(list[m.p], m.s, m.e);
              if (!r) return;
              markRanges.push({ id: m.id, range: r });
              (m.n ? noted : plain).push(r);
            });
            if (plain.length) CSS.highlights.set('babel-mark', new Highlight(...plain)); else CSS.highlights.delete('babel-mark');
            if (noted.length) CSS.highlights.set('babel-note', new Highlight(...noted)); else CSS.highlights.delete('babel-note');
          };
          // Aktuelle Auswahl als Stücke je Absatz: [{p, s, e, t}].
          window.babelSelectionParts = function(){
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return [];
            var range = sel.getRangeAt(0), list = window.babelBlocks(), parts = [];
            for (var i = 0; i < list.length; i++) {
              var el = list[i];
              if (!range.intersectsNode(el)) continue;
              var whole = document.createRange(); whole.selectNodeContents(el);
              var from = range.compareBoundaryPoints(Range.START_TO_START, whole) > 0 ? range : whole;
              var to = range.compareBoundaryPoints(Range.END_TO_END, whole) < 0 ? range : whole;
              var before = document.createRange(); before.selectNodeContents(el); before.setEnd(from.startContainer, from.startOffset);
              var inside = document.createRange(); inside.setStart(from.startContainer, from.startOffset); inside.setEnd(to.endContainer, to.endOffset);
              var s = before.toString().length, t = inside.toString();
              if (t.trim().length) parts.push({ p: i, s: s, e: s + t.length, t: t });
            }
            sel.removeAllRanges();
            return parts;
          };
          var marksAt = function(x, y){
            var ids = [];
            markRanges.forEach(function(m){
              var rects = m.range.getClientRects();
              for (var k = 0; k < rects.length; k++) {
                var r = rects[k];
                if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) { ids.push(m.id); break; }
              }
            });
            return ids;
          };
          window.babelFirstVisible = function(){
            var list = window.babelBlocks(), top = 110, w = window.innerWidth;
            for (var i = 0; i < list.length; i++) {
              var r = list[i].getBoundingClientRect();
              if (window.babelPaged ? (r.right > 0 && r.left < w) : r.bottom > top) return i;
            }
            return 0;
          };
          // Satz im Absatz finden – ohne Leerzeichen verglichen, damit <br> und Zeilenumbrüche nicht stören.
          var findRange = function(el, sentence, from){
            var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), compact = '', map = [];
            while (walker.nextNode()) {
              var n = walker.currentNode, t = n.nodeValue;
              for (var k = 0; k < t.length; k++) { if (!/\\s/.test(t[k])) { compact += t[k]; map.push([n, k]); } }
            }
            var target = sentence.replace(/\\s+/g, '');
            if (!target.length) return null;
            var start = compact.indexOf(target, from);
            if (start < 0) start = compact.indexOf(target);
            if (start < 0) return null;
            window.babelSpeechFrom = start + target.length;
            var a = map[start], b = map[start + target.length - 1], r = document.createRange();
            r.setStart(a[0], a[1]); r.setEnd(b[0], b[1] + 1);
            return r;
          };
          window.babelSpeak = function(i, sentence, follow){
            var old = document.querySelector('.babel-speaking-fallback');
            if (old) old.classList.remove('babel-speaking-fallback');
            if (window.CSS && CSS.highlights) CSS.highlights.delete('babel-speech');
            var list = window.babelBlocks();
            if (i < 0 || i >= list.length) { window.babelSpeechIndex = -1; return; }
            if (window.babelSpeechIndex !== i) { window.babelSpeechIndex = i; window.babelSpeechFrom = 0; }
            var el = list[i], range = sentence ? findRange(el, sentence, window.babelSpeechFrom || 0) : null;
            if (range && window.CSS && CSS.highlights) { CSS.highlights.set('babel-speech', new Highlight(range)); }
            else { el.classList.add('babel-speaking-fallback'); }
            if (!follow) return;
            if (window.babelPaged) {
              var pr = (range || el).getBoundingClientRect(), pw = window.innerWidth;
              if (window.babelCurl) {
                if (pr.left < 0 || pr.left >= pw) post({ type: 'speechPage', page: Math.floor((window.scrollX + pr.left) / pw) });
                return;
              }
              if (pr.left < 0 || pr.left >= pw) {
                window.scrollTo({ left: Math.floor((window.scrollX + pr.left) / pw) * pw, top: 0, behavior: 'smooth' });
              }
              return;
            }
            var r = (range || el).getBoundingClientRect(), top = 110, bottom = window.innerHeight - 150;
            if (r.top < top || r.bottom > bottom) {
              window.scrollTo({ top: Math.max(0, window.scrollY + r.top - window.innerHeight * 0.3), behavior: 'smooth' });
            }
          };
          document.addEventListener('click', function(e){
            if (e.target.closest('a, button, input, select, textarea')) return;
            if ((window.getSelection() + '').length > 0) return;
            // Tippen auf eine Markierung öffnet sie (Notiz, Löschen).
            if (markRanges.length) {
              var hit = marksAt(e.clientX, e.clientY);
              if (hit.length) { post({ type: 'mark', ids: hit }); return; }
            }
            // Beim Vorlesen springt ein Tipp auf einen Absatz dorthin.
            if (window.babelReadAloud) {
              var list = window.babelBlocks();
              for (var i = 0; i < list.length; i++) {
                if (list[i].contains(e.target)) { post({ type: 'speakFrom', paragraph: i }); return; }
              }
            }
            // Seitenweise: linker/rechter Rand blättert, die Mitte blendet die Leisten ein.
            if (window.babelCurl) {
              var cx = e.clientX, cw = window.innerWidth;
              if (cx < cw * 0.28) { post({ type: 'turn', dir: -1 }); return; }
              if (cx > cw * 0.72) { post({ type: 'turn', dir: 1 }); return; }
            } else if (window.babelPaged) {
              var x = e.clientX, w = window.innerWidth;
              if (x < w * 0.28) { if (window.babelTurn(-1) === 'start') post({ type: 'previous' }); return; }
              if (x > w * 0.72) { if (window.babelTurn(1) === 'end') post({ type: 'next' }); return; }
            }
            post({ type: 'tap' });
          });
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
    @AppStorage("reader.font") private var fontID = ReaderDefaults.font
    @AppStorage("reader.fontSize") private var fontSize = ReaderDefaults.fontSize
    @AppStorage("reader.lineHeight") private var lineHeight = ReaderDefaults.lineHeight
    @AppStorage("reader.margin") private var margin = ReaderDefaults.margin
    @AppStorage("reader.justify") private var justify = ReaderDefaults.justify
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = ReaderDefaults.paragraphSpacing
    @AppStorage(VolumeKeyScroller.settingKey) private var volumeScroll = false
    @AppStorage(ReaderDefaults.pagedKey) private var paged = false
    @AppStorage(ReaderDefaults.curlKey) private var curl = false
    @State private var volumeKeys = VolumeKeyScroller()

    @State private var model: ReaderModel
    @ObservedObject private var fetcher = WebFetcher.shared
    @State private var showSettings = false
    @State private var showChapters = false
    @State private var showDetail = false
    @State private var speech = ReadAloudPlayer.shared
    @State private var showSpeech = false

    init(story: Story) {
        _model = State(initialValue: ReaderModel(story: story))
    }

    private var resolvedTheme: ReaderTheme { theme.resolved(colorScheme) }

    private var style: ReaderStyle {
        ReaderStyle(theme: resolvedTheme, font: ReaderFont.find(fontID), fontSize: fontSize,
                    lineHeight: lineHeight, margin: margin, justify: justify, paragraphSpacing: paragraphSpacing, paged: paged)
    }

    var body: some View {
        ZStack {
            resolvedTheme.swiftUIBackground.ignoresSafeArea()

            // Anderer Blättermodus = andere Ansicht: neu aufbauen, an derselben Stelle (siehe `makeUIViewController`).
            ReaderPager(model: model, css: style.css, background: resolvedTheme.swiftUIBackground, paged: paged, curl: paged && curl)
                .id(paged ? (curl ? "book" : "paged") : "scroll")
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
        .sheet(isPresented: $showSpeech) {
            ReadAloudSheet()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(item: Binding(get: { model.openedMarks }, set: { model.openedMarks = $0 })) { selection in
            MarkSheet(selection: selection, model: model)
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
            .environment(\.readerJump, {
                var jump = ReaderJump { chapter in
                    showDetail = false
                    if let chapter { model.jump(to: chapter) }
                }
                jump.jumpToAnchor = { chapter, paragraph in model.jump(to: chapter, anchor: paragraph) }
                return jump
            }())
        }
        .onChange(of: style.css) { _, css in model.applyCSS(css) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.save() }
            updateVolumeKeys()
        }
        .onChange(of: volumeScroll) { _, _ in updateVolumeKeys() }
        .onChange(of: speech.cursor) { _, _ in syncSpeech() }
        .onChange(of: speech.isActive) { _, _ in
            syncSpeech()
            updateVolumeKeys()
        }
        .task {
            model.start()
            volumeKeys.onPress = { [model] direction in model.pager?.scrollPage(direction) }
            model.onSpeakFrom = { [model, speech] chapter, paragraph in speech.play(model.story, chapter: chapter, paragraph: paragraph) }
            updateVolumeKeys()
            syncSpeech()
        }
        .onDisappear {
            model.save()
            volumeKeys.stop()
        }
    }

    /// Lautstärketasten nur abfangen, solange der Reader vorne ist und die Option an ist – beim Vorlesen regeln sie die Lautstärke.
    private func updateVolumeKeys() {
        if volumeScroll && scenePhase == .active && !speech.isActive { volumeKeys.start() } else { volumeKeys.stop() }
    }

    private var speaksThisStory: Bool { speech.story?.key == model.story.key }

    /// Vorlese-Stelle in den Reader übertragen; beim Kapitelwechsel des Vorlesens mitblättern.
    private func syncSpeech() {
        let mine = speaksThisStory
        model.speechActive = mine
        model.speech = mine ? speech.cursor : nil
        if mine, let cursor = speech.cursor, speech.isPlaying, cursor.chapter != model.chapterIndex {
            model.jump(to: cursor.chapter)
        }
        model.pager?.applySpeech()
    }

    /// Lautsprecher-Knopf: startet beim ersten sichtbaren Absatz, läuft es schon, öffnet er die Steuerung.
    private func speechButtonTapped() {
        if speaksThisStory {
            showSpeech = true
            return
        }
        let chapter = model.chapterIndex
        if let pager = model.pager {
            pager.firstVisibleParagraph { paragraph in speech.play(model.story, chapter: chapter, paragraph: paragraph) }
        } else {
            speech.play(model.story, chapter: chapter)
        }
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
                    speechButtonTapped()
                } label: {
                    Image(systemName: speaksThisStory ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.body.weight(.semibold)).frame(width: 24, height: 24)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: speaksThisStory && speech.isPlaying)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(speaksThisStory ? "Vorlesen steuern" : "Vorlesen")

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
    /// Zu einem Absatz eines Kapitels (Markierungen).
    var jumpToAnchor: ((_ chapter: Int, _ paragraph: Double) -> Void)?
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
