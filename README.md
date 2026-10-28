# Babel – E-Reader für AO3, FanFiction.net & Bücher

Native iPhone-App (SwiftUI, iOS 26) mit Liquid Glass.

## Was die App kann

- **AO3**: Der Tab startet direkt mit allen Filtern. Filter-Konfigurationen lassen sich unter einem Namen speichern und mit einem Tipp laden. Werke suchen mit allen wichtigen Filtern. Dazu gehören Fandoms, Beziehungen, Charaktere und Tags (mit AO3-Vorschlägen beim Tippen), Tags ausschließen, Rating, Warnungen und Kategorien (jeweils *egal / muss / ausschließen*), Status, Crossover, Oneshots, Sprache, Wortzahl, Kudos, Aktualisierungsdatum und Sortierung. Suchen lassen sich speichern. Ein Tipp auf einen Tag in der Detailansicht sucht sofort danach.
- **FanFiction.net**: Fandoms über alle Kategorien per Texteingabe suchen, Kategorien durchstöbern, Fandoms merken, Stichwortsuche. Die Filter sind **genau die, die FFN für den jeweiligen Fandom anbietet** (Sortierung, Genre, Rating, Sprache, Länge, Status, Charaktere, „Ohne“-Filter), weil die App sie live von der Seite liest.
- **Bücher**: Project Gutenberg durchsuchen. Das Suchfeld lässt sich auf Titel, Autor:in oder Thema einschränken, dazu gibt es Filter (Sprache, Sortierung …) und Themen-Chips. **Eigene EPUBs** importierst du über den Knopf oben rechts oder mit „Teilen → Babel“.
- **Downloads**: In jeder Ergebnisliste nach rechts wischen lädt eine Geschichte komplett offline, nach links wischen merkt sie vor. Auf der Detailseite: „Als EPUB exportieren“ (für AO3 und FFN), zum Sichern in „Dateien“ oder Öffnen in Bücher.
- **Konten (optional)**: AO3-Lesezeichen, „Später lesen“, Abos und Verlauf bzw. FFN-Favoriten und Follows anzeigen und mit einem Tipp in die Bibliothek übernehmen.
- **Farben**: Paletten aus t3code (hell Iris, dunkel Grove). In den Einstellungen wählst du System/Hell/Dunkel und für beide Modi je eine Palette, mit Vorschau.
- **Link einfügen**: AO3-, FFN- oder .epub-Link einfügen, dann liegt die Geschichte in der Bibliothek.
- **Bibliothek**: Status (Lese ich / Später / Pausiert / Gelesen / Abgebrochen), Favoriten, eigene Sammlungen, Suche, Sortierung, Filter-Chips. Ziehen zum Aktualisieren prüft alle laufenden Geschichten auf **neue Kapitel**.
- **Reader**: merkt sich Kapitel und Scrollposition, hat fünf Farbthemen (inkl. Sepia und OLED-Schwarz), acht Schriften, Größe, Zeilen- und Absatzabstand, Rand und Blocksatz. Ein Tipp blendet die Glas-Leisten ein und aus. Am Kapitelende steht ein „Nächstes Kapitel“-Knopf, das Inhaltsverzeichnis ist als Sheet erreichbar.
- **Offline**: AO3-Werke werden beim ersten Öffnen komplett gespeichert (eine einzige Anfrage). FFN lädt kapitelweise und das nächste Kapitel immer schon im Voraus; „Offline speichern“ holt alles.
- **Weiterlesen**: Die Leiste über der Tab-Bar (iOS 26 Accessory) bringt dich mit einem Tipp zurück in die zuletzt gelesene Geschichte.
- **Ohne Anmeldung** nutzbar. Mit Login siehst du auch Werke, die nur für registrierte Nutzer:innen sichtbar sind, und kannst deine Listen importieren.

## Installieren

1. `Babel.xcodeproj` in **Xcode 26** öffnen. Xcode lädt das Paket SwiftSoup automatisch, das dauert beim ersten Mal kurz.
2. Links das Projekt **Babel** → Target **Babel** → **Signing & Capabilities**:
   - **Team**: deine Apple-ID wählen (kostenlos geht auch).
   - **Bundle Identifier**: auf etwas Eigenes ändern, z. B. `de.deinname.babel`.
3. iPhone per Kabel anschließen, oben als Ziel wählen, dann **▶︎ Run**.
4. Auf dem iPhone: **Einstellungen → Allgemein → VPN & Geräteverwaltung** → deinem Entwicklerprofil vertrauen. Beim ersten Mal muss außerdem unter **Datenschutz & Sicherheit** der **Entwicklermodus** an sein.

Mit kostenloser Apple-ID läuft die App 7 Tage, danach einfach in Xcode nochmal auf Run drücken. Die Bibliothek bleibt dabei erhalten. Mit bezahltem Developer-Account ist sie ein Jahr gültig.

**Falls sich das Projekt nicht öffnen lässt:** `brew install xcodegen`, dann im Ordner `xcodegen generate` ausführen. Das erzeugt das Projekt neu aus `project.yml`.

## Gut zu wissen

- **FanFiction.net & Cloudflare**: FFN schützt sich mit einer Cloudflare-Prüfung. Babel lädt FFN deshalb über einen unsichtbaren Safari-WebView. Verlangt Cloudflare ein Häkchen, erscheint automatisch ein Fenster. Einmal antippen, dann läuft es meist eine ganze Weile ohne Unterbrechung.
- **Rücksicht auf die Seiten / Rate-Limits**: AO3 und FFN haben keine offizielle API und keine dokumentierten Limits. Die App liest die Webseiten wie ein Browser, von deinem Gerät und deiner IP aus. Sie hält Pausen zwischen Anfragen ein. Antwortet eine Seite mit 429 („zu viele Anfragen“), wartet die App automatisch so lange, wie die Seite verlangt, und zeigt das oben an.
- **Seitenänderungen**: AO3 und FFN haben keine offizielle API, Babel liest die Webseiten. Ändern die Seiten ihren Aufbau, muss evtl. ein Parser angepasst werden (`Services/AO3Service.swift`, `Services/FFNService.swift`).

## Aufbau

```
Babel/
  App/         App-Start, Tabs, Weiterlesen-Leiste, Navigation
  Models/      SwiftData: Story, Shelf (Sammlung), Such-Typen
  Services/    AO3, FFN, Gutenberg, EPUB/ZIP, WebView-Loader, Bibliothek
  Views/       Library, AO3, FFN, Books, Search, Reader, Settings
Support/Info.plist   EPUB-Dateityp („Öffnen mit Babel“)
```

## Ideen für später

- Hintergrund-Updates mit Mitteilung bei neuen Kapiteln
- Kudos/Bookmarks auf AO3 direkt aus der App (mit Login)
- Eigenes Icon für „Babel“
- Seitenweises Blättern statt Scrollen, Markierungen und Notizen im Text
- iCloud-Sync der Bibliothek
