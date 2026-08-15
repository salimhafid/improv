import Foundation
import Observation

/// The single source of truth for *what's on screen*: the chosen home city and
/// the one theater currently being viewed. Both Shows and Classes scope to this
/// selection, so the hamburger sidebar and the Setup city picker both drive it.
/// Persisted across launches so the last city + theater are remembered.
@MainActor
@Observable
final class AppState {
    /// Home city (single). Changing it reconciles the selected theater so it
    /// always belongs to the current city.
    var selectedCity: City {
        didSet {
            Self.persist(Self.cityKey, selectedCity.rawValue)
            ensureTheaterInCity()
        }
    }

    /// Currently viewed theaters — a set of `SourceCatalog` source ids. EMPTY
    /// means "All Theaters" (the whole-city feed). Any combination can be on at
    /// once; always reconciled to `selectedCity`.
    var selectedTheaters: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selectedTheaters).sorted(), forKey: Self.theatersKey)
        }
    }

    /// Transient UI state (not persisted).
    var sidebarOpen = false
    var showCityPicker = false
    /// Selected tab (0 Shows, 1 I'm Going, 2 Classes, 3 Tickets) — lets the
    /// sidebar show counts for whichever list is on screen.
    var activeTab = 0
    /// Deep-link target: a ticket id to open in the wallet (set by a notification
    /// tap), consumed by the Tickets tab.
    var openTicketID: String?

    private static let cityKey = "selectedCity"
    private static let theatersKey = "selectedTheaters"
    private static let legacyTheaterKey = "selectedTheater"

    init() {
        let city = (UserDefaults.standard.string(forKey: Self.cityKey))
            .flatMap(City.init(rawValue:)) ?? .newYork
        selectedCity = city
        // Restore the saved selection, keeping only theaters in the saved city.
        // Migrates the old single-select key (its all-theaters sentinel becomes
        // the empty set).
        let cityTheaterIDs = Set(SourceCatalog.all.filter { $0.city == city }.map(\.id))
        if let saved = UserDefaults.standard.stringArray(forKey: Self.theatersKey) {
            selectedTheaters = Set(saved).intersection(cityTheaterIDs)
        } else if let legacy = UserDefaults.standard.string(forKey: Self.legacyTheaterKey) {
            selectedTheaters = cityTheaterIDs.contains(legacy) ? [legacy] : []
        } else if let first = SourceCatalog.all.first(where: { $0.city == city })?.id {
            selectedTheaters = [first]
        } else {
            selectedTheaters = []
        }
    }

    /// Whether the whole-city ("All Theaters") scope is selected.
    var isAllTheaters: Bool { selectedTheaters.isEmpty }

    /// Navigation title for the current scope: the city for All Theaters, the
    /// theater's name for a single pick, a count for a custom mix.
    var scopeTitle: String {
        if isAllTheaters { return selectedCity.rawValue }
        if selectedTheaters.count == 1, let only = selectedTheaters.first {
            return SourceCatalog.entry(only)?.name ?? "Shows"
        }
        return "\(selectedTheaters.count) Theaters"
    }

    /// Does a show/class from `source` fall inside the current scope?
    func matches(_ source: String) -> Bool {
        selectedTheaters.isEmpty || selectedTheaters.contains(source)
    }

    /// Theaters available in the selected city, in catalog order.
    var cityTheaters: [SourceCatalogEntry] {
        SourceCatalog.all.filter { $0.city == selectedCity }
    }

    /// Keep the selection valid for `selectedCity` (called on city change):
    /// drop theaters from other cities; an emptied selection becomes
    /// All Theaters rather than an accidental nothing.
    func ensureTheaterInCity() {
        let valid = Set(cityTheaters.map(\.id))
        let kept = selectedTheaters.intersection(valid)
        if kept != selectedTheaters { selectedTheaters = kept }
    }

    /// Toggle one theater in or out of the mix (drawer stays open so several
    /// can be picked in one visit). Selecting every theater collapses to
    /// All Theaters.
    func toggle(_ id: String) {
        var next = selectedTheaters
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        if next.count == cityTheaters.count { next = [] }
        selectedTheaters = next
    }

    /// Select the whole-city scope and dismiss the drawer.
    func selectAll() {
        selectedTheaters = []
        sidebarOpen = false
    }

    /// Single-select (Setup flow): exactly this theater, drawer closed.
    func select(_ id: String) {
        selectedTheaters = id == SourceCatalog.allTheatersID ? [] : [id]
        sidebarOpen = false
    }

    private static func persist(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
