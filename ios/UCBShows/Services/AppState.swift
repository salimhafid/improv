import Foundation
import Observation

/// The single source of truth for *what's on screen*: the set of theaters being
/// viewed. Theaters span every city (the sidebar lists them all, grouped by
/// city), so selection is one global set — always at least one theater, UCB
/// New York by default. Both Shows and Classes scope to it. Persisted across
/// launches (and mirrored to iCloud via CloudSync) so the user's selection is
/// their new normal.
@MainActor
@Observable
final class AppState {
    /// The out-of-the-box selection.
    static let defaultTheater = "ucb_ny"

    /// Currently viewed theaters — a non-empty set of `SourceCatalog` source
    /// ids, from any mix of cities.
    var selectedTheaters: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selectedTheaters).sorted(), forKey: Self.theatersKey)
        }
    }

    /// Transient UI state (not persisted).
    var sidebarOpen = false
    /// Selected tab (0 Shows, 1 Tickets, 2 Classes) — lets the sidebar show
    /// counts for whichever list is on screen.
    var activeTab = 0
    /// Deep-link target: a ticket id to open in the wallet (set by a notification
    /// tap), consumed by the Tickets tab.
    var openTicketID: String?

    private static let theatersKey = "selectedTheaters"
    private static let legacyTheaterKey = "selectedTheater"

    init() {
        // Restore the saved selection, dropping ids no longer in the catalog.
        // An empty result (fresh install, or the retired "All Theaters"
        // sentinel from older versions) becomes the default theater.
        var restored: Set<String> = []
        if let saved = UserDefaults.standard.stringArray(forKey: Self.theatersKey) {
            restored = Set(saved).intersection(SourceCatalog.showIDs)
        } else if let legacy = UserDefaults.standard.string(forKey: Self.legacyTheaterKey),
                  SourceCatalog.showIDs.contains(legacy) {
            restored = [legacy]
        }
        selectedTheaters = restored.isEmpty ? [Self.defaultTheater] : restored
    }

    /// The single selected theater's name, or nil for a mix — the views fall
    /// back to their own tab name ("Shows" / "Classes").
    var scopeTheaterName: String? {
        guard selectedTheaters.count == 1, let only = selectedTheaters.first else { return nil }
        return SourceCatalog.entry(only)?.name
    }

    /// Whether the selection spans more than one city — rows then tag each
    /// show/class with its city.
    var spansMultipleCities: Bool {
        Set(selectedTheaters.compactMap { SourceCatalog.entry($0)?.city }).count > 1
    }

    /// Does a show/class from `source` fall inside the current scope?
    func matches(_ source: String) -> Bool {
        selectedTheaters.contains(source)
    }

    /// Toggle one theater in or out of the mix (drawer stays open so several
    /// can be picked in one visit). The last selected theater can't be removed
    /// — the selection is never empty.
    func toggle(_ id: String) {
        var next = selectedTheaters
        if next.contains(id) {
            guard next.count > 1 else { return }
            next.remove(id)
        } else {
            next.insert(id)
        }
        selectedTheaters = next
    }

    /// Single-select (Setup flow): exactly this theater, drawer closed.
    func select(_ id: String) {
        selectedTheaters = [id]
        sidebarOpen = false
    }
}
