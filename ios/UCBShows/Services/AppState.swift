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

    /// Currently viewed theater — a `SourceCatalog` source id (e.g. "ucb_ny").
    /// Always valid for `selectedCity`.
    var selectedTheater: String {
        didSet { Self.persist(Self.theaterKey, selectedTheater) }
    }

    /// Transient UI state (not persisted).
    var sidebarOpen = false
    var showCityPicker = false

    private static let cityKey = "selectedCity"
    private static let theaterKey = "selectedTheater"

    init() {
        let city = (UserDefaults.standard.string(forKey: Self.cityKey))
            .flatMap(City.init(rawValue:)) ?? .newYork
        selectedCity = city
        // Restore the saved theater only if it belongs to the saved city;
        // otherwise fall back to that city's first theater.
        let saved = UserDefaults.standard.string(forKey: Self.theaterKey)
        let cityTheaterIDs = SourceCatalog.all.filter { $0.city == city }.map(\.id)
        if let saved, cityTheaterIDs.contains(saved) {
            selectedTheater = saved
        } else {
            selectedTheater = cityTheaterIDs.first ?? ""
        }
    }

    /// Theaters available in the selected city, in catalog order.
    var cityTheaters: [SourceCatalogEntry] {
        SourceCatalog.all.filter { $0.city == selectedCity }
    }

    /// The catalog entry for the currently selected theater.
    var selectedEntry: SourceCatalogEntry? {
        SourceCatalog.entry(selectedTheater)
    }

    /// Keep `selectedTheater` valid for `selectedCity` (called on city change).
    func ensureTheaterInCity() {
        if selectedEntry?.city != selectedCity {
            selectedTheater = cityTheaters.first?.id ?? ""
        }
    }

    /// Pick a theater from the sidebar and dismiss the drawer.
    func select(_ id: String) {
        selectedTheater = id
        sidebarOpen = false
    }

    private static func persist(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
