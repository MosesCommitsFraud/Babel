# Projekt-Kontext für Claude Code

Native iPhone-E-Reader (SwiftUI, **iOS 26**, Liquid Glass) für **AO3**, **FanFiction.net**, Project Gutenberg und eigene EPUBs. Name: **Babel** (vorher Arbeitstitel „Folio“; Target/Scheme/Ordner `Babel`, Bundle-ID `de.babelreader.app`).

Baut und läuft im Simulator (iPhone 18 Pro, iOS 27). Auf echtem Gerät noch nicht getestet.

## Bauen
```sh
xcodegen generate   # nach neuen/gelöschten Dateien – das Projekt listet Dateien explizit
xcodebuild -project Babel.xcodeproj -scheme Babel -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```
Abhängigkeit: SwiftSoup (SPM). Swift 5 Language Mode, Deployment Target 26.0.

## Wünsche des Nutzers
- Ohne Anmeldung nutzbar; AO3-Login optional (WebView → Cookies an URLSession).
- Liquid Glass so konsequent wie sinnvoll (`.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, Tab-Bar-Accessory). Glas nur für Bedienelemente, nicht für Inhalt.
- Hauptlesestoff: AO3 + FFN. Filter wie auf den Websites, Library zum Wiederfinden.
- Kommunikation auf Deutsch.
- Eigene Themes (`Support/Theme.swift`, `PaletteID`): Hexagon (Standard, Salbeigrün passend zum Icon), Pergament, Nebel, Lavendel, Rosé, Tinte – ruhige, entsättigte Töne, je hell + dunkel. Auswahl: `Views/Settings/ThemeSettingsView.swift` (ein Tipp = beide Modi, Mischen optional). Früher t3code-Paletten, auf Wunsch des Nutzers ersetzt. Eigene Farbschemata: `CustomThemeEditor` (Akzent, Hintergrund, Karten, Text je hell/dunkel; Rest wird abgeleitet), gespeichert als JSON unter `theme.custom`, Auswahl-Schlüssel `custom.<uuid>`; `ThemeCatalog` löst eingebaute und eigene auf.
- FFN: Fandom-Suche über alle Kategorien (`FFNFandomStore`, Cache 7 Tage in Caches/ffn-fandoms.json). Fehlende Kategorien gebündelt per `fetch()` in der offenen FFN-Seite (`FFNService.fandoms(categories:)`, 3 parallel, Auswertung per DOMParser im WebView), Rest einzeln. Sortierte Listen + A–Z-Anker (`FFNFandomIndex`) werden im Hintergrund gebaut – nie im `body` sortieren (13.000 Fandoms → Ruckeln).
- Bücher-Tab mit drei Quellen (`Services/BookSources.swift`, `BookLibrary`): Project Gutenberg, Standard Ebooks (HTML-Suche, EPUB-Link braucht `?source=download`, sonst Dankeseite), Internet Archive (advancedsearch-API, nur freie Texte mit EPUB, ohne Zeitschriften; EPUB-Dateiname über `/metadata/<id>`). Suche mit Bereichen (Alles/Titel/Autor:in/Thema), EPUB-Import oben rechts.
- Kein Sideloading-Store mehr (SideStore-Quelle/Release-Skript entfernt), Installation über Xcode.
- Versionen (`project.yml`: `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, danach `xcodegen generate`): bei **jedem Push** Build-Nummer +1 und Version passend zum Umfang hochsetzen – Patch (0.2.x) für Korrekturen/kleine Anpassungen, Minor (0.x.0) für neue Funktionen oder größere Umbauten, Major nur auf Wunsch. Build-Nummer = Anzahl Commits auf `main`. Jede Version bekommt ein Git-Tag `vX.Y.Z` (annotiert, „Babel X.Y.Z (build N)“), mitpushen (`git push origin --tags`). Ältere Commits rückwirkend getaggt (v0.1.0 … v0.23.4). In der App: Einstellungen → Über → „Version 0.23.6 (Build 47)“.
- Git: `main`, Remote `origin` = https://github.com/MosesCommitsFraud/Babel.git. Regelmäßig committen und pushen, **ohne** Claude als Co-Autor, Commit-Nachrichten **auf Englisch**.
- FFN-Stichwortsuche: standardmäßig `match=title` (FFN-Standard `any` vergräbt exakte Titel), dazu Titel-Ranking im Client.
- Reader: Titel oben öffnet die Storyseite als Sheet (`readerJump` springt im offenen Reader), Kapitel als Seiten in einem `UIPageViewController` (`Views/Reader/ReaderPager.swift`, je Kapitel ein eigener WKWebView): Wischen zieht das Nachbarkapitel mit dem Finger herein, Nachbarn (±1) werden nach dem aktuellen Kapitel vorgeladen, ±2 bleiben im Speicher (Position bleibt beim Zurückwischen). Ladesymbol nur, wenn ein Kapitel erst aus dem Netz kommt. Keine Prozentanzeige. Option „Mit Lautstärketasten blättern“ (`VolumeKeyScroller`, aus): kein offizielles API außerhalb von Kamera-Apps → `outputVolume` per KVO beobachten, unsichtbarer `MPVolumeView` versteckt die Anzeige und setzt die Lautstärke zurück; leiser = eine Bildschirmseite weiter (am Kapitelende nächstes Kapitel), lauter = zurück. Im Simulator nicht testbar.
- Nur Hochformat (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` in `project.yml`; das iPad muss alle Richtungen erlauben).
- Bibliothek: Verlauf (`Story.viewedAt` + `lastOpenedAt`), unter „Alle“ „Zuletzt angesehen“, Chips nach Anzahl sortiert.
- AO3-Tab startet mit der Filterwand (eigener `NavigationPath` – nicht `navigationDestination(item:)`, das baute die Ergebnisliste beim Öffnen einer Story neu); Filter lassen sich als Presets speichern (AO3 und FFN).
- Login (AO3 + FFN) optional, um Lesezeichen/Favoriten/Follows zu importieren.

- App-Icon: Icon-Composer-Datei `Babel/AppIcon.icon` (Variante F): drei grüne Glas-Buchrücken auf einem Regalbrett, ohne Rahmen, auf fast weißem Grund; jedes Buch eine eigene Glas-Gruppe für Tiefe im iOS-27-Look. Weitere Entwürfe A–G in `Design/Icon/`. Vorschau: `ictool <datei>.icon --export-image … --design-generation 27` (in `Icon Composer.app/Contents/Executables`).
- Autorenseiten (`Views/Author/AuthorView.swift`): FFN `/u/<id>/` (eigene Geschichten + Favoriten), AO3 `/users/<name>/profile`, `/works`, `/bookmarks` (seitenweise).
- Listenzeilen (`StoryRow`): Titel `.body` semibold, rechts „akt./veröff. TT.MM.JJ“, rechts neben dem Titel Abzeichen aus Symbol + Wort: grünes Blatt „Neu“ (< 14 Tage), blaues Siegel „Abgeschlossen“ (kein „Fertig“-Chip mehr), bei beiden untereinander, kein Pfeil rechts (`.navigationLinkIndicatorVisibility(.hidden)` an jedem Geschichten-Link → gleicher Rand links/rechts), ♥ rot / 🔔 gelb, Chips (Quelle nur mit `showSource`, Rating, Kapitel, Wörter, Sprache), deutliche Bewertungszeile (gefüllte Symbole in Akzentfarbe) + Datum; darunter über die volle Breite Pairing/Genre (Akzentfarbe) und 3 Zeilen Zusammenfassung – auch in der Bibliothek.
- FFN: Chip „Alle“ (alle Kategorien, `FFNFandomStore.index(for: "all")`), Pairing-Filter (`pm`/`_pm`-Häkchen), Filter werden direkt als URL gebaut (Parameter aus FFNs `process_filter()`), Pairing pro Paar (Charaktere A+B / C+D, FFN kennt nur ein `pm`-Häkchen → App filtert zusätzlich nach `relationships`), Charakter-/Sprach-/Genre-Auswahl nach Anzahl Geschichten sortiert (FFNs `/api/lcount/` in der offenen Seite, `FFNCountStore`, Cache 7 Tage). Kategorie-Chips ohne Icons.
- Einstellungen → Suche: Standard-Rating (`DefaultRating`) und Standard-Sprache der Geschichten (`StoryLanguage`, unabhängig von der App-Sprache), gelten für neue AO3-Suchen (`AO3Filters.withDefaults`) und FFN-Listen (`withDefaultRating`).
- `Services/SiteStatus.swift`: AO3/FFN-Ausfälle (5xx, AO3-Wartung = HTTP 418 „Request temporarily denied“, Cloudflare-Fehlerseiten, Timeouts) → `BabelError.siteDown` statt leerer Treffer, → Glas-Banner `.siteStatusBanner(.ao3/.ffn)` in den Suchansichten.
- Bibliothek: Suchfeld immer sichtbar (alle Wörter in Titel/Autor/Fandom/Pairing/Charakteren/Tags/Zusammenfassung), Filter-Sheet `LibraryFilterSheet` kompakt wie FFN (eine Zeile pro Filter → `MultiSelectList` mit Anzahl): Quelle, Rating (AO3+FFN vereinheitlicht), Status, Länge, Sprache, Fandoms, Pairings, Charaktere; aktive Filter als wegtippbare Chips.
- FFN-„Verlauf“ der offiziellen FFN-App (bei Nutzer ~2500) liegt nur lokal in der App – auf der Website gibt es nur Favoriten (80) und Follows (70).
- Innerhalb von Seiten, die per Closure-`NavigationLink` geöffnet werden (Konto, Autor:in, Tags), ebenfalls Closure-Links verwenden – wertbasierte Links griffen dort nicht.

- Sprachen: Deutsch (Quellsprache) und Englisch über `Babel/Localizable.xcstrings`. Literale in `Text/Label/Button/…` werden automatisch übersetzt; Texte, die als `String` weitergereicht werden (Enum-`label`, Fehlermeldungen, `updateMessage`, eigene Parameter wie `GlassChip(title:)`), brauchen `String(localized:)`. Neue Texte: `xcodebuild -exportLocalizations -project Babel.xcodeproj -localizationPath <dir> -exportLanguage en` → fehlende Schlüssel ins Katalog-JSON eintragen. Nie Meldungstexte vergleichen (`hasPrefix`) – dafür gibt es `LibraryManager.messageIsProgress`.

- Detailansicht: Bewertungsleiste direkt unter dem Kopf (FFN Favs/Follows/Reviews, AO3 Kudos/Lesezeichen/Kommentare/Aufrufe), alle Kapitel ohne „Mehr anzeigen“, Reviews/Kommentare als eigene Seite (`Services/CommentsService.swift`, `Views/Library/CommentsView.swift`: FFN `/r/<id>/0/<seite>/` – geprüft; AO3 `/works/<id>?show_comments=true&page=` – ungeprüft, AO3 war in Wartung).
- Listenzeilen: Datum als ein kurzer Text mit Inline-Symbolen (📅 veröffentlicht, ↻ aktualisiert, im laufenden Jahr ohne Jahreszahl) rechts in der Bewertungszeile (ohne Bewertungen rechts in der Pairing/Genre-Zeile, keine fast leere Zeile), immer einzeilig (`ViewThatFits`: beide Daten → nur das jüngste → weniger Kennzahlen); Kennzahlen kurz über `Int.short` (Tausender abgerundet: 4517 → 4k, 10179 → 10k; 1,2M – Deutsch kürzt Tausender sonst nicht ab). Titel und Zusammenfassung mit `.fixedSize(vertical:)`, sonst vermisst die Liste die Zelle falsch (Titel abgeschnitten, ungleiche Abstände zum Trenner), damit Pairing/Genre die volle Breite behalten – keine Pills/Labels mit Abstand. FFN-Tab startet mit „Alle“.
- Detailansicht: Kopf → Knöpfe (Lesen usw.) → Kennzahlen offen auf dem Hintergrund (farbiges Symbol direkt vor der Zahl, Bezeichnung darunter, dünne Trennlinien). Keine Karten und **keine Symbole in Kreisen** (wirkt laut Nutzer „nach KI“). Angaben (Wörter, Kapitel, Daten, Sprache, Rating) als eine Karte mit einer Zeile pro Angabe (Bezeichnung links, Wert rechts) – keine Kachel-Raster, die je nach Gerätebreite ungleich umbrechen. Sammlungs-Menü mit „Neue Sammlung …“ (legt an und ordnet gleich zu).

## Architektur
- `Services/AO3Service.swift` – Such-URL (`/works/search?work_search[...]`), Blurb-/Werk-/Kapitel-Parser, Autocomplete (`/autocomplete/{fandom,relationship,character,freeform,tag}?term=`). Tag-IDs: Ratings 9–13, Warnungen 14,16–20, Kategorien 21–24,116,2246. Mehrere „muss“-Ratings/Kategorien werden als Ausschluss der übrigen umgesetzt (AO3 verknüpft mit UND).
- `Services/FFNService.swift` – FFN liegt hinter Cloudflare → alles über `WebFetcher` (unsichtbarer WKWebView, Challenge-Sheet bei Bedarf). Filter werden live aus den `<select>` der Seite gelesen und per JS angewendet; Fallback-URL-Parameter (srt, g1, r, lan, len, s, c1…).
- `Services/WebFetcher.swift` – serielle Warteschlange, Cloudflare-Erkennung, `needsUserInteraction` → Sheet in RootView/ReaderView. Wartet auf `didCommit` der neuen Seite (sonst wurde manchmal die alte Seite gelesen). Läuft im **Desktop-Modus** mit Mac-Safari-UA: mit iPhone-UA leitet FFN teils auf m.fanfiction.net um (anderes HTML → leere Listen).
- `Services/HTTPClient.swift` – gleicher UA wie der WebView, Takt pro Host/Bucket, nach 429 wartet der ganze Host (`Retry-After`), Banner über `RateLimitStatus`.
- `Services/ImageLoader.swift` – Cover mit Cache; FFN-Cover per URLSession mit WebView-Cookies, sonst `fetch()` in der offenen FFN-Seite.
- `Services/GutenbergService.swift` – direkt gutenberg.org (HTML-Suche mit Präfixen a./t./s./l.), **nicht Gutendex** (dort teils >60 s).
- `Services/EPUBBuilder.swift` – EPUB-Export aus gespeicherten Kapiteln (eigener ZIP-Schreiber, XHTML via SwiftSoup).
- `Views/Account/` – AO3-/FFN-Konto: Listen anzeigen, „Alle übernehmen“.
- `Services/LibraryManager.swift` – Kapitel laden/speichern (`ContentStore`, Application Support), Updates prüfen, EPUB-/Link-Import.
- `Services/ZipArchive.swift` + `EPUBParser.swift` – eigener ZIP-Entpacker (Compression), OPF/NCX/nav.
- `Models/Story.swift` – SwiftData `Story`, `Shelf`. Achtung: kein Attribut `updated` nennen (kollidiert mit Core Datas `isUpdated`) → heißt `lastUpdated`.
- `Views/Reader/` – `ReaderModel` + `ReaderPager` (Kapitelseiten mit WKWebView, injiziertes CSS, Fortschritt per JS-Message), Glas-Leisten.

## Geprüft (Simulator)
AO3-Suche/Blurbs, FFN-Fandoms/Listen/Filter-Apply/Cover, Gutenberg-Suche + Details, Themes hell/dunkel.

## Ungetestete Annahmen (zuerst prüfen)
- AO3-Konto: Benutzername aus `#greeting`, Listen `/users/<n>/bookmarks`, `readings?show=to-read`, `subscriptions?type=works`.
- FFN-Konto mit echtem Login: Login-Erkennung über `#name_login` (FFN schreibt dort per `XUNAME` Name + „Logout“), Favoriten vom öffentlichen Profil `/~name` (`div.z-list.favstories`, im Browser geprüft), Follows über `alert/story.php` (generisches Parsen von `/s/`-Links, mit echtem Konto geprüft: 2 Seiten, `?p=2`). FFN hat keinen Leseverlauf. Abgleich automatisch beim Start (höchstens alle 6 h).
- EPUB-Export in Apple Books öffnen.
- Cloudflare-Challenge im WKWebView auf echtem Gerät.
- AO3 ist zeitweise extrem langsam (60–100 s pro Seite) bzw. liefert 525 – dann helfen nur Cache/Timeouts.

## Offene Ideen
Hintergrund-Updates mit Mitteilung, Kudos/Bookmarks auf AO3, Blättern statt Scrollen, Markierungen, iCloud-Sync, neues Icon für „Babel“.
