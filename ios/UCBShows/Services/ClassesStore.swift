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

/// Where a tapped class-alert notification should land in the Classes tab.
/// Built by the app from the push (see `NotificationRouter`), consumed — and
/// cleared — by `ClassesView`. Foundation-only so the logic harness can drive
/// it.
struct ClassAlertTarget: Equatable {
    /// One per tap, so tapping the same alert twice is two requests to open
    /// it, and a late record fetch can tell whether its tap is still the one
    /// on screen.
    let id: UUID
    /// Watcher school id (== class source id, e.g. "ucb_ny"), when known.
    var school: String?
    /// Feed ids from the record's `classIDs` (`ClassItem.rawID`, e.g.
    /// "ucb_ny/43407"). Exactly one = a per-class alert; several = a
    /// flood-summary alert; none = unknown.
    var classIDs: [String]
    /// The alert's first body line, for the "just posted" banner while the
    /// class hasn't reached the feed yet.
    var titleHint: String?
    /// True from the tap until the alert's record has been fetched. Without
    /// it the view could not tell "ids not known yet" from "an alert naming no
    /// class", and would consume the tap before the record arrived.
    var isProvisional: Bool
    /// When the alert was sent: its record's CloudKit `creationDate` (system
    /// metadata, not a record field). Nil until resolved, or if unknown.
    var alertedAt: Date?

    init(id: UUID = UUID(), school: String?, classIDs: [String] = [],
         titleHint: String? = nil, isProvisional: Bool = false, alertedAt: Date? = nil) {
        self.id = id
        self.school = school
        self.classIDs = classIDs
        self.titleHint = titleHint
        self.isProvisional = isProvisional
        self.alertedAt = alertedAt
    }

    /// Whether the alert went out within `window` of `now` — i.e. whether its
    /// class missing from the feed can still mean "not published yet". The
    /// feed lists upcoming classes only and alert records are never deleted,
    /// so an old alert tapped from Notification Center usually names a class
    /// that has started and left the feed for good. An unknown send time
    /// can't back a "few minutes" promise, so it is not recent; a send time
    /// slightly ahead of `now` (device clock behind the server's) is.
    func isRecent(now: Date, within window: TimeInterval) -> Bool {
        guard let alertedAt else { return false }
        return now.timeIntervalSince(alertedAt) <= window
    }

    /// The school a class-alert subscription id names: "alert/v3/<school>/
    /// <digest>" and "alert/v2/<school>/<category>" (categorized schools),
    /// "alert/<school>/all" (school-wide). Anything else is nil. The push
    /// carries the subscription id for free, so this is what the app shows
    /// while the alert's record is still being fetched — and all it has if
    /// that fetch fails.
    static func school(fromSubscriptionID id: String?) -> String? {
        guard let id else { return nil }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "alert" else { return nil }
        if parts.count == 4, parts[1] == "v2" || parts[1] == "v3", !parts[2].isEmpty {
            return parts[2]
        }
        if parts.count == 3, parts[2] == "all", !parts[1].isEmpty {
            return parts[1]
        }
        return nil
    }

    /// This tap, resolved from its `ClassAlert` record's fields (nil = field
    /// missing, or the fetch failed). Keeps the tap's `id`; the record's
    /// school wins over the one inferred from the subscription id;
    /// `classIDs` is the record's comma-separated list, trimmed, empty
    /// entries dropped; the hint is the body's first line; `alertedAt` is the
    /// record's creation date.
    func resolved(school recordSchool: String?, classIDs field: String?,
                  pushBody: String?, alertedAt: Date? = nil) -> ClassAlertTarget {
        let trimmedSchool = recordSchool?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = (field ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let firstLine = pushBody?.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return ClassAlertTarget(
            id: id,
            school: trimmedSchool.flatMap { $0.isEmpty ? nil : $0 } ?? school,
            classIDs: ids,
            titleHint: firstLine.flatMap { $0.isEmpty ? nil : $0 },
            isProvisional: false,
            alertedAt: alertedAt)
    }
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

    /// When a network fetch last succeeded — the staleness clock behind
    /// `refreshIfStale`. Nil until one has. Ignored by observation: no view
    /// reads it, and every write would otherwise invalidate the Classes tab.
    @ObservationIgnored private var lastFetched: Date?
    /// Network fetches in flight. A foreground at cold launch lands while the
    /// launch fetch is still running; that one is about to answer, so
    /// `refreshIfStale` stands down instead of sending a duplicate.
    @ObservationIgnored private var fetchesInFlight = 0

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
        await refresh(force: false)
    }

    /// Refresh from the network. `force` — the default, since every caller
    /// outside the store is the user pulling, tapping "Try Again", or waiting
    /// on an alerted class — makes the request revalidate with the origin even
    /// inside the CDN's max-age, so an explicit refresh can't "succeed" out of
    /// `URLCache` while offline. The launch and foreground paths pass false
    /// and let the protocol cache answer.
    func refresh(force: Bool = true) async {
        fetchesInFlight += 1
        defer { fetchesInFlight -= 1 }
        do {
            let payload = try await service.fetchRemote(
                policy: force ? .reloadRevalidatingCacheData : .useProtocolCachePolicy)
            apply(payload)
            phase = .loaded
            lastFetched = Date()
        } catch {
            // A caller torn down mid-request (the class-alert lookup in
            // `ClassesView` is cancelled whenever its target changes or the
            // tab goes away) says nothing about connectivity; reporting it
            // as `.offline` would raise the offline banner over a good feed.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            phase = allClasses.isEmpty ? .failed(error.localizedDescription) : .offline
        }
    }

    /// Foreground refresh: the launch fetch is the only automatic one, so an
    /// app left running for days kept showing the class list it launched
    /// with — and a just-alerted class could never appear in it. Throttled
    /// (default: the CDN's 5-minute max-age, inside which a fetch can't see
    /// anything newer anyway) and let the protocol cache answer, so frequent
    /// app switching costs at most a 304.
    func refreshIfStale(maxAge: TimeInterval = 300) async {
        guard fetchesInFlight == 0,
              Self.isStale(lastFetched: lastFetched, now: Date(), maxAge: maxAge) else { return }
        await refresh(force: false)
    }

    /// The staleness decision, pure so the harness can check it: never
    /// fetched, or the last success is more than `maxAge` old. A clock set
    /// backwards (`now` before the stamp) also counts as stale rather than
    /// suppressing refreshes until the clock catches up.
    static func isStale(lastFetched: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let lastFetched else { return true }
        let age = now.timeIntervalSince(lastFetched)
        return age > maxAge || age < 0
    }

    // MARK: Class alerts

    /// The class a tapped alert names, when it names exactly ONE that is in
    /// the feed. A flood-summary alert (several ids) or an unknown one (none)
    /// is nil — the caller opens the school's folder instead. Records written
    /// before alert ids became feed ids carried bare UCB EventIDs ("43407"),
    /// so a bare id with a known school also tries "<school>/<id>".
    func item(for target: ClassAlertTarget) -> ClassItem? {
        guard target.classIDs.count == 1, let id = target.classIDs.first else { return nil }
        if let hit = allClasses.first(where: { $0.rawID == id }) { return hit }
        guard !id.contains("/"), let school = target.school, !school.isEmpty else { return nil }
        let prefixed = "\(school)/\(id)"
        return allClasses.first { $0.rawID == prefixed }
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

    // MARK: Core curriculum

    private static func dateSorted(_ group: [ClassItem]) -> [ClassItem] {
        group.sorted { lhs, rhs in
            let ld = lhs.startDate ?? .distantFuture
            let rd = rhs.startDate ?? .distantFuture
            if ld != rd { return ld < rd }
            return lhs.title < rhs.title
        }
    }

    private static func coreSorted(_ core: [(rank: Int, item: ClassItem)]) -> [ClassItem] {
        core.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
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

    /// Improv Core and Sketch Core lead, then the fixed subject order. Each
    /// class appears once; core courses sort by rank then date, the rest by
    /// date. Internal so the logic harness can drive it directly.
    static func subjectGroups(from classes: [ClassItem], source: String) -> [SubjectGroup] {
        let classified = classes.map {
            (course: ClassCurriculum.course(source: $0.source, title: $0.title, level: $0.level), item: $0)
        }
        let rest = classified.filter { $0.course == nil }.map(\.item)

        var groups: [SubjectGroup] = []
        for curriculum in ClassCurriculum.allCases {
            let core = classified.compactMap { entry -> (rank: Int, item: ClassItem)? in
                guard let course = entry.course, course.curriculum == curriculum else { return nil }
                return (course.rank, entry.item)
            }
            guard !core.isEmpty else { continue }
            groups.append(SubjectGroup(
                id: "\(source)/\(curriculum.rawValue)", title: curriculum.title,
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
