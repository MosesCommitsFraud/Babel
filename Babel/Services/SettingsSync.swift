import Foundation

/// Spiegelt ausgewählte Einstellungen in den iCloud-Schlüsselspeicher. `@AppStorage` bemerkt Änderungen von selbst.
/// Nur Dinge, die auf jedem Gerät gleich sein sollen: keine Anmeldungen, Mitteilungs-Erlaubnis oder Stimmen (je Gerät andere).
final class SettingsSync {
    static let shared = SettingsSync()
    private init() {}

    private static let keys = [
        "reader.theme", "reader.font", "reader.fontSize", "reader.lineHeight", "reader.margin",
        "reader.justify", "reader.paragraphSpacing", ReaderDefaults.pagedKey, ReaderDefaults.curlKey, HighlightSettings.key, VolumeKeyScroller.settingKey,
        AppTheme.lightKey, AppTheme.darkKey, AppearanceMode.key, ThemeCatalog.customKey,
        DefaultRating.key, StoryLanguage.key, "search.history", "ffn.pinned", "ffn.savedFilters", "ffn.searchMatch",
        "ao3.savedSearches", "library.sort", OPDSCatalogStore.key, "royalroad.list", "checkUpdatesOnLaunch", "readAloud.rate",
    ]

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            self?.pull(changed ?? Self.keys)
        })
        // Auch das Echo von `pull` landet hier, ändert aber nichts: `push` schreibt nur Abweichungen.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: local, queue: nil) { [weak self] _ in
            self?.push()
        })
        cloud.synchronize()
        pull(Self.keys)
        push()
    }

    private func pull(_ changed: [String]) {
        for key in changed where Self.keys.contains(key) {
            guard let value = cloud.object(forKey: key), !isSame(value, local.object(forKey: key)) else { continue }
            local.set(value, forKey: key)
        }
    }

    private func push() {
        for key in Self.keys {
            guard let value = local.object(forKey: key), !isSame(value, cloud.object(forKey: key)) else { continue }
            cloud.set(value, forKey: key)
        }
    }

    private func isSame(_ a: Any, _ b: Any?) -> Bool {
        guard let b else { return false }
        return (a as AnyObject).isEqual(b)
    }
}
