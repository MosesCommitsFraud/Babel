import SwiftUI

/// Kudos/Lesezeichen/Abo (AO3) bzw. Follow/Favorit (FFN) direkt auf der Seite setzen – nur mit Anmeldung.
struct SiteActionsBar: View {
    let story: Story
    @Environment(\.theme) private var theme
    @Environment(LibraryManager.self) private var library
    @AppStorage("ao3.username") private var ao3User = ""
    @State private var ffn = FFNAccount.shared

    @State private var ao3State: SiteActions.AO3State?
    @State private var ffnDone: Set<String> = []
    @State private var busy: String?
    @State private var error: String?

    private var available: Bool {
        switch story.source {
        case .ao3: !ao3User.isEmpty
        case .ffn: ffn.isLoggedIn
        default: false
        }
    }

    var body: some View {
        if available {
            VStack(alignment: .leading, spacing: 8) {
                Text(story.source == .ao3 ? "Auf AO3" : "Auf FanFiction.net")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if story.source == .ao3 {
                            button("Kudos", symbol: "hand.thumbsup", done: ao3State?.kudosGiven == true, id: "kudos") {
                                ao3State = try await SiteActions.ao3Perform(.kudos, workID: story.sourceID)
                                library.updateMessage = String(localized: "Kudos gegeben")
                            }
                            button("Lesezeichen", symbol: "bookmark", done: ao3State?.bookmarked == true, id: "bookmark") {
                                ao3State = try await SiteActions.ao3Perform(.bookmark, workID: story.sourceID)
                                library.updateMessage = String(localized: "Auf AO3 gemerkt")
                            }
                            button(ao3State?.subscribed == true ? "Abonniert" : "Abonnieren", symbol: "bell",
                                   done: ao3State?.subscribed == true, id: "subscribe", allowUndo: true) {
                                ao3State = try await SiteActions.ao3Perform(.subscribe, workID: story.sourceID)
                                library.updateMessage = ao3State?.subscribed == true
                                    ? String(localized: "Auf AO3 abonniert") : String(localized: "Abo beendet")
                            }
                        } else {
                            button("Follow", symbol: "bell", done: ffnDone.contains("follow"), id: "follow") {
                                let message = try await SiteActions.ffnFollowFav(storyID: story.sourceID, follow: true, favorite: false)
                                ffnDone.insert("follow")
                                library.updateMessage = message.isEmpty ? String(localized: "Auf FanFiction.net gefolgt") : message
                            }
                            button("Favorit", symbol: "heart", done: ffnDone.contains("fav"), id: "fav") {
                                let message = try await SiteActions.ffnFollowFav(storyID: story.sourceID, follow: false, favorite: true)
                                ffnDone.insert("fav")
                                library.updateMessage = message.isEmpty ? String(localized: "Auf FanFiction.net favorisiert") : message
                            }
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .task(id: story.key) {
                guard story.source == .ao3, ao3State == nil else { return }
                ao3State = try? await SiteActions.ao3State(workID: story.sourceID)
            }
        }
    }

    /// Glas-Kapsel; gefüllt, wenn schon gesetzt. Einmal Gesetztes (Kudos, Favorit) lässt sich hier nicht zurücknehmen.
    private func button(_ title: LocalizedStringKey, symbol: String, done: Bool, id: String, allowUndo: Bool = false,
                        action: @escaping () async throws -> Void) -> some View {
        Button {
            guard busy == nil, !done || allowUndo else { return }
            busy = id
            error = nil
            Task {
                do { try await action() } catch { self.error = error.localizedDescription }
                busy = nil
            }
        } label: {
            HStack(spacing: 5) {
                if busy == id { ProgressView().controlSize(.small) }
                else { Image(systemName: done ? symbol + ".fill" : symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(done ? AnyShapeStyle(theme.primaryText) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(done ? .regular.tint(theme.primary.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
        .disabled(busy != nil && busy != id)
    }
}
