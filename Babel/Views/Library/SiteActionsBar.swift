import SwiftUI

/// Follow/Favorit (FFN) bzw. Kudos/Lesezeichen/Abo (AO3) direkt auf der Seite – nur mit Anmeldung.
/// Sitzt direkt unter den Lesen-Knöpfen; gleich breite Glas-Kapseln, gefüllt = gesetzt, nochmal tippen = zurücknehmen.
struct SiteActionsBar: View {
    let story: Story
    @Environment(\.theme) private var theme
    @Environment(LibraryManager.self) private var library
    @AppStorage("ao3.username") private var ao3User = ""
    @State private var ffn = FFNAccount.shared

    @State private var ao3State: SiteActions.AO3State?
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
            VStack(alignment: .leading, spacing: 6) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if story.source == .ao3 { ao3Buttons } else { ffnButtons }
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

    // MARK: FanFiction.net

    @ViewBuilder
    private var ffnButtons: some View {
        let following = ffn.followIDs.contains(story.sourceID)
        let favorite = ffn.favoriteIDs.contains(story.sourceID)
        button(following ? "Gefolgt" : "Folgen", symbol: "bell", done: following, id: "follow") {
            try await toggleFFN(.follows, on: !following)
        }
        button(favorite ? "Favorisiert" : "Favorisieren", symbol: "heart", done: favorite, id: "fav") {
            try await toggleFFN(.favorites, on: !favorite)
        }
    }

    private func toggleFFN(_ list: FFNService.AccountList, on: Bool) async throws {
        if on {
            _ = try await SiteActions.ffnFollowFav(storyID: story.sourceID, follow: list == .follows, favorite: list == .favorites)
        } else {
            try await SiteActions.ffnRemove(storyID: story.sourceID, from: list)
        }
        ffn.setMembership(list, storyID: story.sourceID, on)
        library.updateMessage = switch (list, on) {
        case (.follows, true): String(localized: "Auf FanFiction.net gefolgt")
        case (.follows, false): String(localized: "Auf FanFiction.net entfolgt")
        case (.favorites, true): String(localized: "Auf FanFiction.net favorisiert")
        case (.favorites, false): String(localized: "Aus FFN-Favoriten entfernt")
        }
    }

    // MARK: AO3

    @ViewBuilder
    private var ao3Buttons: some View {
        let state = ao3State
        // AO3 lässt Kudos nicht zurücknehmen.
        button("Kudos", symbol: "hand.thumbsup", done: state?.kudosGiven == true, id: "kudos", undoable: false) {
            ao3State = try await SiteActions.ao3Perform(.kudos, workID: story.sourceID)
            library.updateMessage = String(localized: "Kudos gegeben")
        }
        button(state?.bookmarked == true ? "Gemerkt" : "Merken", symbol: "bookmark", done: state?.bookmarked == true, id: "bookmark") {
            let remove = ao3State?.bookmarked == true
            ao3State = try await SiteActions.ao3Perform(remove ? .removeBookmark : .bookmark, workID: story.sourceID)
            library.updateMessage = remove ? String(localized: "AO3-Lesezeichen entfernt") : String(localized: "Auf AO3 gemerkt")
        }
        button(state?.subscribed == true ? "Abonniert" : "Abonnieren", symbol: "bell", done: state?.subscribed == true, id: "subscribe") {
            ao3State = try await SiteActions.ao3Perform(.subscribe, workID: story.sourceID)
            library.updateMessage = ao3State?.subscribed == true ? String(localized: "Auf AO3 abonniert") : String(localized: "Abo beendet")
        }
    }

    // MARK: Knopf

    private func button(_ title: LocalizedStringKey, symbol: String, done: Bool, id: String, undoable: Bool = true,
                        action: @escaping () async throws -> Void) -> some View {
        Button {
            guard busy == nil, !done || undoable else { return }
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
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(done ? AnyShapeStyle(theme.primaryText) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(done ? .regular.tint(theme.primary.opacity(0.22)).interactive() : .regular.interactive(), in: .capsule)
        .disabled(busy != nil && busy != id)
        .accessibilityValue(done ? Text("Aktiv") : Text(""))
    }
}
