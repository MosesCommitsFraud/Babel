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
- Farben aus t3code (`~/DEV/t3code/apps/mobile/generated-uniwind-themes.css`): Standard hell **Iris**, dunkel **Grove** (wie in t3code eingestellt). Einstellungsseite nach dem Vorbild von t3code (`apps/web/src/components/settings/ThemeSettings.tsx`): Modus-Kacheln System/Hell/Dunkel und Palettenkarten mit App-Wireframe (`Views/Settings/ThemeSettingsView.swift`, Paletten in `Support/Theme.swift`).
- FFN: Fandom-Suche über alle Kategorien (`FFNFandomStore`, Cache 7 Tage in Caches/ffn-fandoms.json).
- Bücher = Project Gutenberg; Suche mit Bereichen (Alles/Titel/Autor:in/Thema), EPUB-Import oben rechts.
- Git: `main`, Remote `origin` = https://github.com/MosesCommitsFraud/Babel.git. Regelmäßig committen und pushen, **ohne** Claude als Co-Autor, Commit-Nachrichten **auf Englisch**.
- FFN-Stichwortsuche: standardmäßig `match=title` (FFN-Standard `any` vergräbt exakte Titel), dazu Titel-Ranking im Client.
- Reader: Titel oben öffnet die Storyseite als Sheet (`readerJump` springt im offenen Reader), Wischen links/rechts wechselt Kapitel, keine Prozentanzeige.
- Bibliothek: Verlauf (`Story.viewedAt` + `lastOpenedAt`), unter „Alle“ „Zuletzt angesehen“, Chips nach Anzahl sortiert.
- AO3-Tab startet mit der Filterwand (eigener `NavigationPath` – nicht `navigationDestination(item:)`, das baute die Ergebnisliste beim Öffnen einer Story neu); Filter lassen sich als Presets speichern (AO3 und FFN).
- Login (AO3 + FFN) optional, um Lesezeichen/Favoriten/Follows zu importieren.

- App-Icon: Icon-Composer-Datei `Babel/AppIcon.icon` (stilisiertes Buch, hellgrüner Hintergrund, SVG-Ebenen in `Assets/`). Vorschau: `ictool Babel/AppIcon.icon --export-image --output-file x.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1` (ictool liegt in `Icon Composer.app/Contents/Executables`). Altes Logo-Entwurf in `Design/Icon/`.
- Autorenseiten (`Views/Author/AuthorView.swift`): FFN `/u/<id>/` (eigene Geschichten + Favoriten), AO3 `/users/<name>/profile`, `/works`, `/bookmarks` (seitenweise).
- Listenzeilen: zwei Chip-Zeilen (Quelle, Rating farbig, Status/Kapitel, Wörter | Datum, Sprache, Pairing oder Genre).
- FFN-„Verlauf“ der offiziellen FFN-App (bei Nutzer ~2500) liegt nur lokal in der App – auf der Website gibt es nur Favoriten (80) und Follows (70).
- Innerhalb von Seiten, die per Closure-`NavigationLink` geöffnet werden (Konto, Autor:in, Tags), ebenfalls Closure-Links verwenden – wertbasierte Links griffen dort nicht.

- Sprachen: Deutsch (Quellsprache) und Englisch über `Babel/Localizable.xcstrings`. Literale in `Text/Label/Button/…` werden automatisch übersetzt; Texte, die als `String` weitergereicht werden (Enum-`label`, Fehlermeldungen, `updateMessage`, eigene Parameter wie `GlassChip(title:)`), brauchen `String(localized:)`. Neue Texte: `xcodebuild -exportLocalizations -project Babel.xcodeproj -localizationPath <dir> -exportLanguage en` → fehlende Schlüssel ins Katalog-JSON eintragen. Nie Meldungstexte vergleichen (`hasPrefix`) – dafür gibt es `LibraryManager.messageIsProgress`.

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
- `Views/Reader/` – WKWebView-Reader mit injiziertem CSS, Fortschritt per JS-Message, Glas-Leisten.

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
