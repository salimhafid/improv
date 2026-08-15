import Foundation
import Observation

/// A city's worth of classes for the sectioned Classes list.
struct ClassSection: Identifiable {
    let id: String          // city raw value, or "other"
    let title: String       // "New York" / "Los Angeles" / "Chicago"
    let symbol: String
    let classes: [ClassItem]
}

/// Single source of truth for the Classes tab: loads the `/classes.json` feed,
/// caches it for offline, and exposes filtered + city-grouped output. Mirrors
/// `ShowsStore` for the class data type.
@MainActor
@Observable
final class ClassesStore {
    enum Phase: Equatable {
        case loading
        case loaded
        case offline
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var allClasses: [ClassItem] = []
    private(set) var lastUpdated: Date?
    private(set) var sourcesInfo: [SourceInfo] = []

    var filters: ClassFilters {
        didSet { Self.persistFilters(filters) }
    }

    private let service: FeedService<ClassesPayload>
    private static let filtersKey = "classFilters"

    init(service: FeedService<ClassesPayload> = .classes) {
        self.service = service
        self.filters = Self.loadFilters() ?? ClassFilters()
    }

    private static func loadFilters() -> ClassFilters? {
        guard let data = UserDefaults.standard.data(forKey: filtersKey) else { return nil }
        return try? JSONDecoder().decode(ClassFilters.self, from: data)
    }

    private static func persistFilters(_ filters: ClassFilters) {
        if let data = try? JSONEncoder().encode(filters) {
            UserDefaults.standard.set(data, forKey: filtersKey)
        }
    }

    /// Drop a level filter not present in the current city+theater scope so a
    /// stale selection can't silently empty the list. Driven by the view.
    func reconcileLevel(city: String, theaters: Set<String>) {
        guard !allClasses.isEmpty else { return }
        if let l = filters.level, !availableLevels(city: city, theaters: theaters).contains(l) {
            filters.level = nil
        }
    }

    // MARK: Loading

    func loadInitial() async {
        if allClasses.isEmpty {
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
            phase = allClasses.isEmpty ? .failed(error.localizedDescription) : .offline
        }
    }

    private func apply(_ payload: ClassesPayload) {
        allClasses = payload.classes
        lastUpdated = payload.generatedAt.flatMap(DateUtils.parseTimestamp)
        sourcesInfo = payload.sources ?? []
    }

    var updatedLabel: String? {
        lastUpdated.map { DateUtils.relativeUpdated($0) }
    }

    // MARK: Filter option sources (scoped to the current city + theater)

    /// Classes in a given city + theater scope (no other filters). The
    /// all-theaters sentinel widens the scope to the whole city.
    func scoped(city: String, theaters: Set<String>) -> [ClassItem] {
        allClasses.filter {
            $0.city == city
                && (theaters.isEmpty || theaters.contains($0.source))
        }
    }

    /// Distinct levels/tracks present in the scope, sorted.
    func availableLevels(city: String, theaters: Set<String>) -> [String] {
        Set(scoped(city: city, theaters: theaters).map(\.level)).filter { !$0.isEmpty }.sorted()
    }

    func levelFilterIsUseful(city: String, theaters: Set<String>) -> Bool {
        !availableLevels(city: city, theaters: theaters).isEmpty
    }

    // MARK: Filtering

    func filtered(city: String, theaters: Set<String>, searchText: String = "") -> [ClassItem] {
        let query = searchText.folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return allClasses.filter { matches($0, query: query, city: city, theaters: theaters) }
    }

    private func matches(_ item: ClassItem, query: String, city: String, theaters: Set<String>) -> Bool {
        if item.city != city { return false }
        if !theaters.isEmpty, !theaters.contains(item.source) { return false }
        if let level = filters.level, item.level != level { return false }
        if filters.openOnly, item.isFull { return false }
        if !query.isEmpty, !item.searchHay.contains(query) { return false }
        return true
    }

    // MARK: Core curriculum (UCB Improv 101–401)

    static let coreSectionID = "__core__"

    /// Rank in UCB's core improv sequence: 101 → 0 … 401 → 3, nil for
    /// everything else. Matched on title or level prefix so a renamed feed
    /// subtitle ("Improv 101: Improv Basics") still qualifies; "Musical
    /// Improv 101" etc. don't (prefix is anchored at the start).
    static func coreRank(_ item: ClassItem) -> Int? {
        guard item.source == "ucb_ny" || item.source == "ucb_la" else { return nil }
        for (rank, number) in ["101", "201", "301", "401"].enumerated() {
            let prefix = "Improv \(number)"
            if item.title.hasPrefix(prefix) || item.level.hasPrefix(prefix) { return rank }
        }
        return nil
    }

    // MARK: Sections (grouped by level within the city+theater scope)

    func sections(city: String, theaters: Set<String>, searchText: String = "") -> [ClassSection] {
        Self.buildSections(from: filtered(city: city, theaters: theaters, searchText: searchText))
    }

    /// Pure grouping core, static so tests can drive it without a store: the
    /// UCB core sequence first (when present), then level groups A→Z, "Other"
    /// (levelless) last, each sorted by start date then title.
    static func buildSections(from allItems: [ClassItem]) -> [ClassSection] {
        var items = allItems

        // UCB's core sequence gets its own pinned section up top (collapsible
        // in the view) so students tracking 101→401 skip the electives.
        var sections: [ClassSection] = []
        // Rank each item once (decorate–sort–undecorate) instead of matching
        // title prefixes inside the comparator.
        let ranked = items.map { (rank: Self.coreRank($0), item: $0) }
        let core = ranked.filter { $0.rank != nil }
        if !core.isEmpty {
            items = ranked.filter { $0.rank == nil }.map(\.item)
            let sorted = core.sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return (lhs.rank ?? 0) < (rhs.rank ?? 0) }
                let ld = lhs.item.startDate ?? .distantFuture
                let rd = rhs.item.startDate ?? .distantFuture
                if ld != rd { return ld < rd }
                return lhs.item.title < rhs.item.title
            }.map(\.item)
            sections.append(ClassSection(id: Self.coreSectionID, title: "Core Curriculum",
                                         symbol: "graduationcap", classes: sorted))
        }

        let byLevel = Dictionary(grouping: items, by: \.level)
        let keys = byLevel.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }  // empty ("Other") last
            return a < b
        }
        sections += keys.map { key in
            let sorted = (byLevel[key] ?? []).sorted { lhs, rhs in
                let ld = lhs.startDate ?? .distantFuture
                let rd = rhs.startDate ?? .distantFuture
                if ld != rd { return ld < rd }
                return lhs.title < rhs.title
            }
            return ClassSection(id: key.isEmpty ? "__nolevel__" : key,
                                title: key.isEmpty ? "Other" : key,
                                symbol: "graduationcap",
                                classes: sorted)
        }
        return sections
    }
}
