import Foundation
import Observation

/// A subject sub-group inside a school folder.
struct SubjectGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let classes: [ClassItem]
}

/// One school's folder in the Classes tab.
struct SchoolFolder: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
    let subjects: [SubjectGroup]
}

/// The full school-folder layout for the Classes tab: every school in the
/// selection's cities, picked theaters first.
///
/// `Equatable` (and the memo behind it) is load-bearing for more than speed:
/// rebuilding meant fresh array buffers every body evaluation, which never
/// match SwiftUI's cheap diff, so every card and row re-rendered on every
/// keystroke and every expand.
struct SchoolFolderLayout: Equatable {
    let selected: [SchoolFolder]
    /// Cheap stable value for `.animation(value:)`: changes exactly when the
    /// folder set or its order changes, never on expand/collapse.
    let orderKey: String
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

    private let service: FeedService<ClassesPayload>

    /// Memo for `schoolFolders`, which is called from inside `ClassesView.body`.
    /// `@ObservationIgnored` is LOAD-BEARING: an observed write during body
    /// evaluation would invalidate the view that just read it — an endless
    /// re-render loop. Single-entry, which is safe only because `ClassesView`
    /// is the sole caller; a second view calling it with a different key in the
    /// same frame would thrash the cache to a 0% hit rate.
    @ObservationIgnored private var layoutCache: (key: LayoutKey, layout: SchoolFolderLayout)?

    /// Bumped on every feed apply. Deliberately NOT `@ObservationIgnored`:
    /// reading it in `schoolFolders` is what registers the view's dependency on
    /// the feed on the cache-hit path, where `allClasses` is never touched. Only
    /// ever written from `apply`, never during body evaluation.
    private var feedVersion = 0

    /// Diagnostic: how many times the layout was actually rebuilt, i.e. the
    /// memo's miss count. Read by the offline logic harness.
    @ObservationIgnored private(set) var layoutBuildCount = 0

    private struct LayoutKey: Equatable {
        let theaters: Set<String>
        /// Already normalized (see `normalizedQuery`).
        let query: String
        let version: Int
    }

    init(service: FeedService<ClassesPayload> = .classes) {
        self.service = service
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

    /// The single write path for class data — both loaders above go through it,
    /// as does the offline logic harness (which has no network and no bundle
    /// cache to load from).
    func apply(_ payload: ClassesPayload) {
        allClasses = payload.classes
        lastUpdated = payload.generatedAt.flatMap(DateUtils.parseTimestamp)
        sourcesInfo = payload.sources ?? []
        feedVersion &+= 1
        layoutCache = nil
    }

    var updatedLabel: String? {
        lastUpdated.map { DateUtils.relativeUpdated($0) }
    }

    // MARK: Filtering

    /// Fold + trim + lowercase, to match `ClassItem.searchHay`. Hoisted out of
    /// `filtered` so the memo key and the match can share one normalization.
    static func normalizedQuery(_ text: String) -> String {
        SearchText.normalized(text)
    }

    /// Classes matching the search text within the selection's cities (see
    /// `classScope` — the Classes tab browses city-wide, not theater-by-theater).
    func filtered(theaters: Set<String>, searchText: String = "") -> [ClassItem] {
        filtered(theaters: theaters, normalized: Self.normalizedQuery(searchText))
    }

    private func filtered(theaters: Set<String>, normalized query: String) -> [ClassItem] {
        let scope = SourceCatalog.classScope(for: theaters)
        let needle = Array(query.utf8)   // once, not once per item
        return allClasses.filter { matches($0, needle: needle, theaters: scope) }
    }

    private func matches(_ item: ClassItem, needle: [UInt8], theaters: Set<String>) -> Bool {
        if !theaters.isEmpty, !theaters.contains(item.source) { return false }
        if !needle.isEmpty, !Self.containsBytes(item.searchBytes, needle) { return false }
        return true
    }

    /// Plain substring scan over pre-folded UTF-8 — see `SearchText.contains`,
    /// which `ShowsStore` shares. Kept as a named entry point here so the logic
    /// harness can assert the parity through the store it guards.
    static func containsBytes(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        SearchText.contains(hay, needle)
    }

    // MARK: Core curriculum (UCB Improv 101–401)

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

    private static func dateSorted(_ group: [ClassItem]) -> [ClassItem] {
        group.sorted { lhs, rhs in
            let ld = lhs.startDate ?? .distantFuture
            let rd = rhs.startDate ?? .distantFuture
            if ld != rd { return ld < rd }
            return lhs.title < rhs.title
        }
    }

    private static func coreSorted(_ core: [(rank: Int?, item: ClassItem)]) -> [ClassItem] {
        core.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return (lhs.rank ?? 0) < (rhs.rank ?? 0) }
            let ld = lhs.item.startDate ?? .distantFuture
            let rd = rhs.item.startDate ?? .distantFuture
            if ld != rd { return ld < rd }
            return lhs.item.title < rhs.item.title
        }.map(\.item)
    }

    // MARK: School Folders

    /// Every school in the selection's cities gets a top-level folder. Within
    /// each city the picked theaters lead, so the sidebar choice still sits on
    /// top. Folders open on tap only — the list lands fully collapsed so all of
    /// the city's schools are visible at once.
    /// Called from inside `ClassesView.body`, so it is memoized on
    /// (theaters, query, feed). A rebuild is ~0.2 ms and, worse, hands back
    /// freshly allocated buffers that defeat SwiftUI's diff; the cache turns
    /// every expand, collapse and scroll-triggered re-evaluation into a
    /// comparison.
    func schoolFolders(theaters: Set<String>, searchText: String = "") -> SchoolFolderLayout {
        let key = LayoutKey(theaters: theaters,
                            query: Self.normalizedQuery(searchText),
                            version: feedVersion)
        if let cached = layoutCache, cached.key == key { return cached.layout }
        let layout = buildSchoolFolders(theaters: theaters, query: key.query)
        layoutCache = (key, layout)
        return layout
    }

    private func buildSchoolFolders(theaters: Set<String>, query: String) -> SchoolFolderLayout {
        layoutBuildCount &+= 1
        let items = filtered(theaters: theaters, normalized: query)
        let scope = SourceCatalog.classScope(for: theaters)
        let bySource = Dictionary(grouping: items, by: \.source)

        let inScope = SourceCatalog.all.filter { scope.isEmpty || scope.contains($0.id) }
        // Two filters rather than a sort: Swift's sort isn't documented stable,
        // and catalog order within a city has to survive.
        let order = City.allCases.flatMap { city -> [SourceCatalogEntry] in
            let entries = inScope.filter { $0.city == city }
            return entries.filter { theaters.contains($0.id) }
                 + entries.filter { !theaters.contains($0.id) }
        }

        let folders: [SchoolFolder] = order.compactMap { entry in
            let classes = bySource[entry.id] ?? []
            // A theater the user explicitly picked keeps its folder even with
            // no classes: Logan Square and The Playground have shows but zero
            // classes in the feed, so picking them in the sidebar used to make
            // the chosen theater silently vanish from this list. Suppressed
            // during a search, where an empty result is self-explanatory.
            let picked = theaters.contains(entry.id)
            guard !classes.isEmpty || (picked && query.isEmpty) else { return nil }
            return SchoolFolder(id: entry.id, name: entry.name, count: classes.count,
                                subjects: Self.subjectGroups(from: classes, source: entry.id))
        }
        return SchoolFolderLayout(selected: folders,
                                  orderKey: folders.map(\.id).joined(separator: "|"))
    }

    /// Core Curriculum pinned first, then the fixed subject order, date-sorted
    /// within. Internal rather than private only so the logic harness can drive
    /// it directly — `schoolFolders` is the app's entry point.
    static func subjectGroups(from classes: [ClassItem], source: String) -> [SubjectGroup] {
        let ranked = classes.map { (rank: coreRank($0), item: $0) }
        let core = ranked.filter { $0.rank != nil }
        let rest = ranked.filter { $0.rank == nil }.map(\.item)

        var groups: [SubjectGroup] = []
        if !core.isEmpty {
            groups.append(SubjectGroup(
                id: "\(source)/core", title: "Core Curriculum",
                classes: coreSorted(core)))
        }

        let bySubject = Dictionary(grouping: rest, by: \.subject)
        for subject in ClassItem.subjectOrder {
            guard let group = bySubject[subject], !group.isEmpty else { continue }
            groups.append(SubjectGroup(
                id: "\(source)/\(subject)", title: subject,
                classes: dateSorted(group)))
        }
        return groups
    }
}
