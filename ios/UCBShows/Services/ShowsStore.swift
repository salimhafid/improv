import Foundation
import Observation

/// A day's worth of shows for the sectioned feed.
struct DaySection: Identifiable {
    let id: String          // dayKey ("yyyy-MM-dd" or "tba")
    let date: Date?
    let title: String       // "Today" / "Tomorrow" / "Friday, June 26" / "Dates TBA"
    let shows: [Show]

    /// Groups shows into date sections keyed on each show's venue-local day.
    /// Shared by the feed and the Tickets tab's I'm-Going section (mixed cities).
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

    private let service: FeedService<ShowsPayload>
    private static let filtersKey = "filters"

    /// Memo for `sections`, which is called from inside `ShowsFeedView.body`.
    /// `@ObservationIgnored` is LOAD-BEARING: an observed write during body
    /// evaluation would invalidate the view that just read it — an endless
    /// re-render loop. Single-entry, which is safe only because `ShowsFeedView`
    /// is the sole caller; a second view calling it with a different key in the
    /// same frame would thrash the cache to a 0% hit rate.
    @ObservationIgnored private var sectionCache: (key: SectionKey, sections: [DaySection])?

    /// Bumped on every feed apply. Deliberately NOT `@ObservationIgnored`:
    /// reading it in `sections` is what registers the view's dependency on the
    /// feed on the cache-hit path, where `allShows` is never touched. Only ever
    /// written from `apply`, never during body evaluation.
    private var feedVersion = 0

    /// Diagnostic: how many times the sections were actually rebuilt, i.e. the
    /// memo's miss count. Read by the offline logic harness.
    @ObservationIgnored private(set) var sectionBuildCount = 0

    /// Reading `filters` here is also what registers the view's dependency on
    /// the filter set, which the cache-hit path would otherwise skip.
    private struct SectionKey: Equatable {
        let theaters: Set<String>
        /// Already normalized (see `SearchText.normalized`).
        let query: String
        let filters: Filters
        let version: Int
        /// See `dayStamp` — the only key component that moves on its own.
        let days: [Date]
    }

    /// Start-of-today in every city the app covers. Unlike the classes layout,
    /// this pipeline reads the clock: `inDateWindow` measures from the show's
    /// own city midnight, past shows are pruned against it, and
    /// `DaySection.group` labels sections "Today" / "Tomorrow". Without this
    /// the cache would happily serve yesterday's "Today" to a feed left on
    /// screen across midnight. Necessary, not sufficient: it makes the memo
    /// miss on the next body evaluation after midnight, but something else
    /// (a scene-phase change, a feed apply) still has to trigger that
    /// evaluation. Cheap — the calendars are pre-cached, so it's a few
    /// `startOfDay` calls and no formatting.
    private func dayStamp() -> [Date] {
        let now = self.now()
        return City.allCases.map { DateUtils.calendar(in: $0.timeZone).startOfDay(for: now) }
    }

    /// The clock. Injectable so the offline logic harness can pin "today"
    /// (fixtures don't age out, and the section memo can't flake at midnight).
    @ObservationIgnored var now: () -> Date = { Date() }

    /// Keep a show listed until well after it has started — the same grace
    /// `GoingStore` gives a hearted show, so a late show doesn't vanish from
    /// the feed while still on the I'm-Going list.
    static let expiryGrace: TimeInterval = 6 * 3600

    init(service: FeedService<ShowsPayload> = .shows) {
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

    /// Drop filter selections not available in the current theater scope
    /// (venues are theater-specific; comedy types vary by theater) so a stale
    /// selection can't silently empty the feed. Driven by the view when the scope
    /// changes and after each successful load.
    ///
    /// A scope with no shows at all (a source whose scrape failed and was
    /// carried over empty) offers nothing to reconcile against, so it is left
    /// alone rather than wiping filters that are still valid once it's back —
    /// the wipe would persist, and reach every device via iCloud.
    func reconcileFilters(theaters: Set<String>) {
        guard !scoped(theaters: theaters).isEmpty else { return }
        if let v = filters.venue {
            // The venue picker is hidden with a single venue unless a filter is
            // already set (`FilterSheet`), so a lone venue must not survive here
            // as a filter hiding every venue-less show.
            let venues = availableVenues(theaters: theaters)
            if venues.count < 2 || !venues.contains(v) { filters.venue = nil }
        }
        if !filters.comedyTypes.isEmpty {
            let kept = filters.comedyTypes.intersection(Set(availableTypes(theaters: theaters)))
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
        await refresh(force: false)
    }

    /// Refresh from the network. `force` — the default, since every caller
    /// outside the store is the user pulling or tapping "Try Again" — makes
    /// the request revalidate with the origin even inside the CDN's max-age,
    /// so an explicit refresh can't "succeed" out of `URLCache` while offline.
    /// The launch path passes false and lets the protocol cache answer.
    func refresh(force: Bool = true) async {
        do {
            let payload = try await service.fetchRemote(
                policy: force ? .reloadRevalidatingCacheData : .useProtocolCachePolicy)
            apply(payload)
            phase = .loaded
        } catch {
            phase = allShows.isEmpty ? .failed(error.localizedDescription) : .offline
        }
    }

    /// The single write path for show data — both loaders above go through it,
    /// as does the offline logic harness (which has no network and no bundle
    /// cache to load from).
    func apply(_ payload: ShowsPayload) {
        allShows = payload.shows.sorted { lhs, rhs in
            (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
        }
        lastUpdated = payload.generatedAt.flatMap(DateUtils.parseTimestamp)
        sourcesInfo = payload.sources ?? []
        feedVersion &+= 1
        sectionCache = nil
    }

    var updatedLabel: String? {
        lastUpdated.map { DateUtils.relativeUpdated($0) }
    }

    // MARK: Sources

    func info(for id: String) -> SourceInfo? { sourcesInfo.first { $0.id == id } }

    /// A source is available unless the feed explicitly reports it failed. Unknown
    /// (feed not loaded yet) is treated as available.
    func isAvailable(_ id: String) -> Bool { info(for: id)?.ok ?? true }

    // MARK: Filter option sources (scoped to the current theaters)

    /// Shows in a given theater scope (no other filters) — the basis for
    /// filter option lists and the feed. The empty set means every theater.
    func scoped(theaters: Set<String>) -> [Show] {
        allShows.filter { theaters.isEmpty || theaters.contains($0.source) }
    }

    func availableVenues(theaters: Set<String>) -> [String] {
        Set(scoped(theaters: theaters).map(\.venue)).filter { !$0.isEmpty }.sorted()
    }

    func availableTypes(theaters: Set<String>) -> [String] {
        Set(scoped(theaters: theaters).flatMap(\.comedyTypes)).sorted()
    }

    // MARK: Filtering

    /// Shows in the theater scope, refined by the active filters + search.
    func filtered(theaters: Set<String>, searchText: String = "") -> [Show] {
        filtered(theaters: theaters, normalized: SearchText.normalized(searchText))
    }

    private func filtered(theaters: Set<String>, normalized query: String) -> [Show] {
        let needle = Array(query.utf8)   // once, not once per show
        let cutoffs = pastCutoffs()      // likewise — a `startOfDay` per city, not per show
        return allShows.filter { !isPast($0, cutoffs: cutoffs) && matches($0, needle: needle, theaters: theaters) }
    }

    /// Per-zone instant before which a show has come and gone: the venue's
    /// start of today, or `expiryGrace` ago if that is earlier — so a late
    /// show still lists just past midnight while nothing from yesterday
    /// lingers into the afternoon. The backend prunes the feed daily; this
    /// covers the cache a device serves while offline for days.
    private func pastCutoffs() -> [TimeZone: Date] {
        let now = self.now()
        let grace = now.addingTimeInterval(-Self.expiryGrace)
        return Dictionary(City.allCases.map { city in
            (city.timeZone, min(DateUtils.calendar(in: city.timeZone).startOfDay(for: now), grace))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func isPast(_ show: Show, cutoffs: [TimeZone: Date]) -> Bool {
        guard let date = show.startDate, let cutoff = cutoffs[show.cityTimeZone] else { return false }
        return date < cutoff
    }

    private func matches(_ show: Show, needle: [UInt8], theaters: Set<String>) -> Bool {
        if !theaters.isEmpty, !theaters.contains(show.source) { return false }
        if let venue = filters.venue, show.venue != venue { return false }
        if !filters.comedyTypes.isEmpty,
           filters.comedyTypes.isDisjoint(with: Set(show.comedyTypes)) { return false }
        if filters.livestreamOnly, !show.isLivestream { return false }
        if filters.freeOnly, !show.isFree { return false }
        if filters.dateWindow != .all, !inDateWindow(show) { return false }
        if !needle.isEmpty, !SearchText.contains(show.searchBytes, needle) { return false }
        return true
    }

    private func inDateWindow(_ show: Show) -> Bool {
        guard let date = show.startDate else { return false }
        // Reckon "today"/windows in the show's own city timezone.
        let cal = DateUtils.calendar(in: show.cityTimeZone)
        let now = self.now()
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
    /// the window starts in the past, but `filtered` prunes passed shows first.
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

    /// Date-grouped sections of the current theater scope's shows (filtered).
    /// Called from inside `ShowsFeedView.body`, so it is memoized on
    /// (theaters, query, filters, feed). A rebuild filters and re-groups the
    /// whole feed and, worse, hands back freshly allocated buffers that defeat
    /// SwiftUI's diff, so every row re-rendered on every body evaluation.
    func sections(theaters: Set<String>, searchText: String = "") -> [DaySection] {
        let key = SectionKey(theaters: theaters,
                             query: SearchText.normalized(searchText),
                             filters: filters,
                             version: feedVersion,
                             days: dayStamp())
        if let cached = sectionCache, cached.key == key { return cached.sections }
        sectionBuildCount &+= 1
        let sections = DaySection.group(filtered(theaters: theaters, normalized: key.query))
        sectionCache = (key, sections)
        return sections
    }
}
