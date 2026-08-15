import Foundation
import Observation

/// A city's worth of classes for the sectioned Classes list.
struct ClassSection: Identifiable {
    let id: String          // city raw value, or "other"
    let title: String       // "New York" / "Los Angeles" / "Chicago"
    let symbol: String
    let classes: [ClassItem]
}

/// How the Classes list is organized. Subject buckets span every school
/// consistently; Level keeps each school's own ladder; Date is a flat
/// soonest-first calendar.
enum ClassGrouping: String, CaseIterable, Identifiable {
    case subject, level, date
    var id: String { rawValue }
    var label: String {
        switch self {
        case .subject: return "Subject"
        case .level: return "Level"
        case .date: return "Date"
        }
    }
}

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

    /// How the list is grouped (persisted).
    var grouping: ClassGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey) }
    }
    private static let groupingKey = "classGrouping"

    private let service: FeedService<ClassesPayload>

    init(service: FeedService<ClassesPayload> = .classes) {
        self.service = service
        self.grouping = UserDefaults.standard.string(forKey: Self.groupingKey)
            .flatMap(ClassGrouping.init(rawValue:)) ?? .subject
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

    // MARK: Sections (grouped within the theater scope)

    func sections(theaters: Set<String>, searchText: String = "") -> [ClassSection] {
        Self.buildSections(from: filtered(theaters: theaters, searchText: searchText),
                           grouping: grouping)
    }

    /// Pure grouping core, static so tests can drive it without a store.
    /// Subject/Level keep the pinned UCB Core Curriculum section up top;
    /// Date is purely chronological (months, TBA last).
    static func buildSections(from allItems: [ClassItem],
                              grouping: ClassGrouping = .level) -> [ClassSection] {
        switch grouping {
        case .level: return levelSections(from: allItems)
        case .subject: return subjectSections(from: allItems)
        case .date: return dateSections(from: allItems)
        }
    }

    /// Subject buckets in a fixed order, Core pinned first, date-sorted within.
    private static func subjectSections(from allItems: [ClassItem]) -> [ClassSection] {
        var items = allItems
        var sections: [ClassSection] = []
        let ranked = items.map { (rank: Self.coreRank($0), item: $0) }
        let core = ranked.filter { $0.rank != nil }
        if !core.isEmpty {
            items = ranked.filter { $0.rank == nil }.map(\.item)
            sections.append(ClassSection(id: Self.coreSectionID, title: "Core Curriculum",
                                         symbol: "graduationcap",
                                         classes: coreSorted(core)))
        }
        let bySubject = Dictionary(grouping: items, by: \.subject)
        for subject in ClassItem.subjectOrder {
            guard let group = bySubject[subject], !group.isEmpty else { continue }
            sections.append(ClassSection(id: "subject/\(subject)", title: subject,
                                         symbol: subjectSymbol(subject),
                                         classes: dateSorted(group)))
        }
        return sections
    }

    /// Chronological: month sections soonest-first, undated last.
    private static func dateSections(from allItems: [ClassItem]) -> [ClassSection] {
        let dated = allItems.filter { $0.startDate != nil }
        let undated = allItems.filter { $0.startDate == nil }
        let tz = TimeZone(identifier: "America/New_York") ?? .current
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        fmt.timeZone = tz   // must match the bucketing calendar or labels
                            // drift a month at boundaries on non-ET devices
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let byMonth = Dictionary(grouping: dated) { item -> Date in
            let d = item.startDate ?? .distantFuture
            return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
        }
        var sections = byMonth.keys.sorted().map { month in
            ClassSection(id: "month/\(month.timeIntervalSince1970)",
                         title: fmt.string(from: month), symbol: "calendar",
                         classes: dateSorted(byMonth[month] ?? []))
        }
        if !undated.isEmpty {
            sections.append(ClassSection(id: "month/tba", title: "Dates TBA",
                                         symbol: "calendar",
                                         classes: undated.sorted { $0.title < $1.title }))
        }
        return sections
    }

    private static func subjectSymbol(_ subject: String) -> String {
        switch subject {
        case "Musical Improv": return "music.mic"
        case "Sketch & Writing": return "pencil.and.outline"
        case "Acting & Character": return "person.crop.rectangle"
        case "Stand-Up": return "mic"
        case "Clowning": return "face.smiling"
        case "Storytelling": return "book"
        case "Teens & Youth": return "figure.2.and.child.holdinghands"
        case "Workshops & Drop-Ins": return "sparkles"
        default: return "theatermasks"
        }
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

    /// The original level grouping.
    private static func levelSections(from allItems: [ClassItem]) -> [ClassSection] {
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
            sections.append(ClassSection(id: Self.coreSectionID, title: "Core Curriculum",
                                         symbol: "graduationcap", classes: coreSorted(core)))
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

    private static func subjectGroups(from classes: [ClassItem], source: String) -> [SubjectGroup] {
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
