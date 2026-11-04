import Foundation
import SwiftData

/// Öffnet die Bibliothek: dieselbe Datei wie immer (`default.store`), abgeglichen über die private iCloud-Datenbank.
/// Ohne iCloud-Konto bleibt alles lokal; meldet sich jemand später an, lädt iOS die Bibliothek nach oben.
enum LibraryStore {
    static let schema = Schema([Story.self, Shelf.self])
    /// Muss zu `com.apple.developer.icloud-container-identifiers` in `project.yml` passen.
    static let containerID = "iCloud.de.babelreader.app"

    private static let preparedKey = "cloud.libraryPrepared.v1"
    /// `false`, wenn die Bibliothek diesmal nur lokal geöffnet werden konnte.
    private(set) static var isCloudEnabled = false

    static func open() -> ModelContainer {
        if prepareExistingLibrary() {
            do {
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .private(containerID)))
                isCloudEnabled = true
                return container
            } catch {
                print("iCloud-Abgleich nicht verfügbar: \(error)")
            }
        }
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        } catch {
            fatalError("Bibliothek konnte nicht geöffnet werden: \(error)")
        }
    }

    /// Einmalig, bevor CloudKit die Bibliothek zum ersten Mal sieht: Sicherung anlegen, das Schema lokal
    /// umstellen und jeder Zeile ihre `syncID` geben. Die Umstellung vergibt sonst allen denselben Standardwert,
    /// und `CloudSync` könnte doppelte Zeilen nicht auf allen Geräten gleich auflösen.
    /// Schlägt das fehl, bleibt es diesmal beim lokalen Öffnen.
    private static func prepareExistingLibrary() -> Bool {
        guard !UserDefaults.standard.bool(forKey: preparedKey) else { return true }
        let store = ModelConfiguration(schema: schema, cloudKitDatabase: .none).url
        if FileManager.default.fileExists(atPath: store.path) {
            backUp(store)
            do {
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
                let context = ModelContext(container)
                for story in try context.fetch(FetchDescriptor<Story>()) { story.syncID = UUID().uuidString }
                for shelf in try context.fetch(FetchDescriptor<Shelf>()) { shelf.syncID = UUID().uuidString }
                try context.save()
            } catch {
                print("Bibliothek konnte nicht für iCloud vorbereitet werden: \(error)")
                return false
            }
        }
        UserDefaults.standard.set(true, forKey: preparedKey)
        return true
    }

    /// Kopie des Stands vor der Umstellung, liegt unter Application Support/Babel/Backups (nicht in `Stories`).
    private static func backUp(_ store: URL) {
        let backups = store.deletingLastPathComponent().appendingPathComponent("Babel/Backups/before-icloud", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: backups.path) else { return }
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: store.path + suffix)
            try? FileManager.default.copyItem(at: source, to: backups.appendingPathComponent(source.lastPathComponent))
        }
    }
}
