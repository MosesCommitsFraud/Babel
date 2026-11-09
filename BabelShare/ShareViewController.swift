import UIKit
import UniformTypeIdentifiers

/// „In Babel öffnen“ im Teilen-Menü: nimmt Links (AO3, FanFiction.net, Royal Road, EPUB-Adressen) und EPUB-Dateien an,
/// legt sie im gemeinsamen Ordner ab und zeigt kurz eine Bestätigung. Die App holt sie beim nächsten Öffnen ab.
final class ShareViewController: UIViewController {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    private static let german = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
    private static func text(_ de: String, _ en: String) -> String { german ? de : en }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        buildCard()
        show(symbol: "arrow.down.circle", title: Self.text("Wird hinzugefügt …", "Adding …"), detail: "")
        Task { await handle() }
    }

    private func buildCard() {
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -22),
        ])
    }

    private func show(symbol: String, title: String, detail: String) {
        icon.image = UIImage(systemName: symbol)
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
    }

    private func handle() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var added = 0
        var unsupported = 0
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.epub.identifier) {
                if let file = await file(from: provider), (try? ShareInbox.add(epub: file)) != nil { added += 1 } else { unsupported += 1 }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                guard let url = await url(from: provider) else { unsupported += 1; continue }
                if url.isFileURL {
                    if url.pathExtension.lowercased() == "epub", (try? ShareInbox.add(epub: url)) != nil { added += 1 } else { unsupported += 1 }
                } else if ShareInbox.isSupported(url), (try? ShareInbox.add(link: url)) != nil {
                    added += 1
                } else {
                    unsupported += 1
                }
            }
        }
        if added > 0 {
            show(symbol: "checkmark.circle.fill",
                 title: Self.text("Zu Babel hinzugefügt", "Added to Babel"),
                 detail: Self.text("Liegt beim nächsten Öffnen in deiner Bibliothek.", "It will be in your library the next time you open Babel."))
        } else {
            show(symbol: "exclamationmark.triangle",
                 title: Self.text("Das kann Babel nicht öffnen", "Babel can't open this"),
                 detail: Self.text("Unterstützt werden Geschichten von AO3, FanFiction.net und Royal Road sowie EPUB-Dateien.",
                                   "Supported: stories from AO3, FanFiction.net and Royal Road, and EPUB files."))
        }
        try? await Task.sleep(for: .seconds(added > 0 ? 1.3 : 2.6))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Die Datei gibt es nur während des Aufrufs – deshalb gleich an einen eigenen Ort kopieren.
    private func file(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.epub.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil)
            }
        }
    }

    private func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
