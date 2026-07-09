import Foundation
import Observation

/// A day's worth of shows for the sectioned feed.
struct DaySection: Identifiable {
    let id: String          // dayKey ("yyyy-MM-dd" or "tba")
    let date: Date?
    let title: String       // "Today" / "Tomorrow" / "Friday, June 26" / "Dates TBA"
    let shows: [Show]

    /// Groups shows into date sections keyed on each show's venue-local day.
    /// Shared by the feed and the I'm Going tab (which can mix cities).
    static func group(_ shows: [Show]) -> [DaySection] {
        let byDay = Dictionary(grouping: shows, by: \.dayKey)
        return byDay.keys.sorted { a, b in
            if a == "tba" { return false }
            if b == "tba" { return true }
            return a < b
        }.map { key in
            let items = byDay[key] ?? []
            let first = items.first
            let date = first?.startDate
            let title = date.map {
                DateUtils.sectionTitle(for: $0, in: first?.cityTimeZone ?? .newYork)
            } ?? "Dates to be announced"
            return DaySection(id: key, date: date, title: title, shows: items)
        }
    }
}

/// Single source of truth for the app: loads the feed, caches it for offline,
/// and exposes filtered + date-grouped output for the views.
@MainActor
@Observable
final class ShowsStore {
    enum Phase: Equatable {
        case loading        // first load, nothing to show yet
        case loaded         // showing fresh data
        case offline        // showing cached data, refresh failed
        case failed(String) // nothing to show and refresh failed
    }

    private(set) var phase: Phase = .loading
    private(set) var allShows: [Show] = []
    private(set) var lastUpdated: Date?
    private(set) var sourcesInfo: [SourceInfo] = []

    /// Active filters (persisted across launches).
    var filters: Filters {
        didSet { Self.persistFilters(filters) }
    }

    private let service: ShowsService
    private static let filtersKey = "filters"

    init(service: ShowsService = ShowsService()) {
        self.service = service
        self.filters = Self.loadFilters() ?? Filters()
    }

    private static func loadFilters() -> Filters? {
        guard let data = UserDefaults.standard.data(forKey: filtersKey) else { return nil }
        return try? JSONDecoder().decode(Filters.self, from: data)
    }

    private static func persistFilters(_ filters: Filters) {
        if let data = try? JSONEncoder().encode(filters) {
            UserDefaults.standard.set(data, forKey: filtersKey)
        }
    }

    /// Drop filter selections not available in the current city+theater scope
    /// (venues are theater-specific; comedy types vary by theater) so a stale
    /// selection can't silently empty the feed. Driven by the view when the scope
    /// changes and after each successful load.
    func reconcileFilters(city: String, theater: String) {
        guard !allShows.isEmpty else { return }
        if let v = filters.venue, !availableVenues(city: city, theater: theater).contains(v) {
            filters.venue = nil
        }
        if !filters.comedyTypes.isEmpty {
            let kept = filters.comedyTypes.intersection(Set(availableTypes(city: city, theater: theater)))
            if kept != filters.comedyTypes { filters.comedyTypes = kept }
        }
    }

    // MARK: Loading

    /// Show cached data instantly (if any), then refresh from the network. The
    /// cache read + decode runs off the main actor to avoid a launch hitch.
    func loadInitial() async {
        if allShows.isEmpty {
            let service = self.service
            if let cached = await Task.detached(priority: .utility, operation: { service.cachedPayload() }).value {
                apply(cached)
                phase = .loaded
            }
        }
        await refresh()
    }

    func refresh() async {
        do {
            let payload = try await service.fetchRemote()
            apply(payload)
            phase = .loaded
        } catch {
            phase = allShows.isEmpty ? .failed(error.localizedDescription) : .offline
        }
    }

    private func apply(_ payload: ShowsPayload) {
        allShows = payload.shows.sorted { lhs, rhs in
            (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
        }
        lastUpdated = payload.generatedAt.flatMap(DateUtils.parseTimestamp)
        sourcesInfo = payload.sources ?? []
    }

    var updatedLabel: String? {
        lastUpdated.map { DateUtils.relativeUpdated($0) }
    }

    // MARK: Sources

    func info(for id: String) -> SourceInfo? { sourcesInfo.first { $0.id == id } }

    /// A source is available unless the feed explicitly reports it failed. Unknown
    /// (feed not loaded yet) is treated as available.
    func isAvailable(_ id: String) -> Bool { info(for: id)?.ok ?? true }

    // MARK: Filter option sources (scoped to the current city + theater)

    /// Shows in a given city + theater scope (no other filters) — the basis for
    /// filter option lists and the per-theater feed. The all-theaters sentinel
    /// widens the scope to the whole city.
    func scoped(city: String, theater: String) -> [Show] {
        allShows.filter {
            $0.city == city
                && (theater == SourceCatalog.allTheatersID || $0.source == theater)
        }
    }

    func availableVenues(city: String, theater: String) -> [String] {
        Set(scoped(city: city, theater: theater).map(\.venue)).filter { !$0.isEmpty }.sorted()
    }

    func availableTypes(city: String, theater: String) -> [String] {
        Set(scoped(city: city, theater: theater).flatMap(\.comedyTypes)).sorted()
    }

    // MARK: Filtering

    /// Shows in the city+theater scope, refined by the active filters + search.
    func filtered(city: String, theater: String, searchText: String = "") -> [Show] {
        let query = searchText.folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return allShows.filter { matches($0, query: query, city: city, theater: theater) }
    }

    private func matches(_ show: Show, query: String, city: String, theater: String) -> Bool {
        if show.city != city { return false }
        if theater != SourceCatalog.allTheatersID, show.source != theater { return false }
        if let venue = filters.venue, show.venue != venue { return false }
        if !filters.comedyTypes.isEmpty,
           filters.comedyTypes.isDisjoint(with: Set(show.comedyTypes)) { return false }
        if filters.livestreamOnly, !show.isLivestream { return false }
        if filters.freeOnly, !show.isFree { return false }
        if filters.dateWindow != .all, !inDateWindow(show) { return false }
        if !query.isEmpty {
            let hay = (show.title + " " + show.excerpt + " " + show.comedyTypes.joined(separator: " "))
                .folding(options: .diacriticInsensitive, locale: .current).lowercased()
            if !hay.contains(query) { return false }
        }
        return true
    }

    private func inDateWindow(_ show: Show) -> Bool {
        guard let date = show.startDate else { return false }
        // Reckon "today"/windows in the show's own city timezone.
        let cal = DateUtils.calendar(in: show.cityTimeZone)
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        switch filters.dateWindow {
        case .all:
            return true
        case .week:
            guard let end = cal.date(byAdding: .day, value: 7, to: startOfToday) else { return true }
            return date >= startOfToday && date <= end
        case .twoWeeks:
            guard let end = cal.date(byAdding: .day, value: 14, to: startOfToday) else { return true }
            return date >= startOfToday && date <= end
        case .weekend:
            guard let weekend = upcomingWeekend(now: now, calendar: cal) else { return false }
            return date >= weekend.start && date < weekend.end
        }
    }

    /// Bounds of the upcoming weekend: from Friday 00:00 up to Monday 00:00
    /// (Fri–Sun — comedy audiences count Friday night as the weekend). Mid-weekend
    /// the window starts in the past, but passed shows aren't in the feed anyway.
    private func upcomingWeekend(now: Date, calendar cal: Calendar) -> (start: Date, end: Date)? {
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today) // 1 = Sun ... 7 = Sat
        let friOffset: Int
        switch weekday {
        case 1: friOffset = -2          // Sunday → this weekend's Friday
        case 7: friOffset = -1          // Saturday
        default: friOffset = 6 - weekday
        }
        guard let friday = cal.date(byAdding: .day, value: friOffset, to: today),
              let monday = cal.date(byAdding: .day, value: 3, to: friday) else { return nil }
        return (friday, monday)
    }

    // MARK: Sections

    /// Date-grouped sections of the current city+theater shows (filtered).
    func sections(city: String, theater: String, searchText: String = "") -> [DaySection] {
        DaySection.group(filtered(city: city, theater: theater, searchText: searchText))
    }
}
