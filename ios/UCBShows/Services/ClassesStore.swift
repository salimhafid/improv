import Foundation
import Observation

/// A subject sub-group inside a school folder.
struct SubjectGroup: Identifiable {
    let id: String
    let title: String
    let classes: [ClassItem]
}

/// One school's folder in the Classes tab.
struct SchoolFolder: Identifiable {
    let id: String
    let name: String
    let count: Int
    let subjects: [SubjectGroup]
}

/// The full school-folder layout for the Classes tab: every school in the
/// selection's cities, picked theaters first.
struct SchoolFolderLayout {
    let selected: [SchoolFolder]
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

    private func apply(_ payload: ClassesPayload) {
        allClasses = payload.classes
        lastUpdated = payload.generatedAt.flatMap(DateUtils.parseTimestamp)
        sourcesInfo = payload.sources ?? []
    }

    var updatedLabel: String? {
        lastUpdated.map { DateUtils.relativeUpdated($0) }
    }

    // MARK: Filtering

    /// Classes matching the search text within the selection's cities (see
    /// `classScope` — the Classes tab browses city-wide, not theater-by-theater).
    func filtered(theaters: Set<String>, searchText: String = "") -> [ClassItem] {
        let query = searchText.folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope = SourceCatalog.classScope(for: theaters)
        return allClasses.filter { matches($0, query: query, theaters: scope) }
    }

    private func matches(_ item: ClassItem, query: String, theaters: Set<String>) -> Bool {
        if !theaters.isEmpty, !theaters.contains(item.source) { return false }
        if !query.isEmpty, !item.searchHay.contains(query) { return false }
        return true
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
    func schoolFolders(theaters: Set<String>, searchText: String = "") -> SchoolFolderLayout {
        let items = filtered(theaters: theaters, searchText: searchText)
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
            guard !classes.isEmpty else { return nil }
            return SchoolFolder(id: entry.id, name: entry.name, count: classes.count,
                                subjects: Self.subjectGroups(from: classes, source: entry.id))
        }
        return SchoolFolderLayout(selected: folders)
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
