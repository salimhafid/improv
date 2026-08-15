import Foundation
import Observation

/// The single source of truth for *what's on screen*: the set of theaters being
/// viewed. Theaters span every city (the sidebar lists them all, grouped by
/// city), so selection is one global set. Both Shows and Classes scope to it.
/// Persisted across launches so the last selection is remembered.
@MainActor
@Observable
final class AppState {
    /// Currently viewed theaters — a set of `SourceCatalog` source ids, from any
    /// mix of cities. EMPTY means "All Theaters" (everything, everywhere).
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
        // Migrates the old single-select key (its all-theaters sentinel becomes
        // the empty set).
        if let saved = UserDefaults.standard.stringArray(forKey: Self.theatersKey) {
            selectedTheaters = Set(saved).intersection(SourceCatalog.allIDs)
        } else if let legacy = UserDefaults.standard.string(forKey: Self.legacyTheaterKey) {
            selectedTheaters = SourceCatalog.allIDs.contains(legacy) ? [legacy] : []
        } else {
            selectedTheaters = []
        }
    }

    /// Whether the everything scope ("All Theaters") is selected.
    var isAllTheaters: Bool { selectedTheaters.isEmpty }

    /// The single selected theater's name, or nil for All Theaters / a mix —
    /// the views fall back to their own tab name ("Shows" / "Classes").
    var scopeTheaterName: String? {
        guard selectedTheaters.count == 1, let only = selectedTheaters.first else { return nil }
        return SourceCatalog.entry(only)?.name
    }

    /// Does a show/class from `source` fall inside the current scope?
    func matches(_ source: String) -> Bool {
        selectedTheaters.isEmpty || selectedTheaters.contains(source)
    }

    /// Toggle one theater in or out of the mix (drawer stays open so several
    /// can be picked in one visit). Selecting every theater collapses to
    /// All Theaters.
    func toggle(_ id: String) {
        var next = selectedTheaters
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        if next.count == SourceCatalog.all.count { next = [] }
        selectedTheaters = next
    }

    /// Select the everything scope and dismiss the drawer.
    func selectAll() {
        selectedTheaters = []
        sidebarOpen = false
    }

    /// Single-select (Setup flow): exactly this theater, drawer closed.
    func select(_ id: String) {
        selectedTheaters = id == SourceCatalog.allTheatersID ? [] : [id]
        sidebarOpen = false
    }
}
