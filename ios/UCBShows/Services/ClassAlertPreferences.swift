import Foundation

/// The category contract shared by alert preferences, UI, and subscription
/// planning. This layer has no CloudKit or notification-permission side effects.
enum ClassAlertCatalog {
    struct School: Identifiable {
        let id: String
        let name: String
        let city: String
    }

    static let ucbSchools: [School] = [
        School(id: "ucb_ny", name: "UCB New York", city: "New York"),
        School(id: "ucb_la", name: "UCB Los Angeles", city: "Los Angeles"),
        School(id: "ucb_online", name: "UCB Online", city: "Online"),
    ]
    static let bccSchool = School(id: "brooklyn_cc", name: "Brooklyn Comedy Collective", city: "New York")
    static let otherSchools: [School] = [
        School(id: "magnet", name: "Magnet Theater", city: "New York"),
        School(id: "wgis_ny", name: "WGIS New York", city: "New York"),
        School(id: "wgis_la", name: "WGIS Los Angeles", city: "Los Angeles"),
        School(id: "annoyance", name: "The Annoyance", city: "Chicago"),
        School(id: "io_chicago", name: "iO Theater", city: "Chicago"),
        School(id: "second_city", name: "The Second City", city: "Chicago"),
        School(id: "logan_square", name: "Logan Square Improv", city: "Chicago"),
    ]

    static let coreCategoryKeys: Set<String> = ["improv_core", "sketch_core"]
    static let ucbCategories: [(key: String, label: String)] = [
        ("improv_core", "Improv Core"),
        ("sketch_core", "Sketch Core"),
        ("improv", "Improv"),
        ("improv_electives", "Improv Electives"),
        ("sketch_character", "Sketch & Character"),
        ("sketch_electives", "Sketch Electives"),
        ("musical_improv", "Musical Improv"),
        ("standup", "Stand-Up"),
        ("clowning", "Clowning"),
        ("acting", "Acting"),
        ("writing_programs", "Writing Programs"),
        ("featured_programs", "Featured Programs"),
        ("workshops", "Workshops"),
        ("intensives", "Intensives"),
        ("other", "Everything Else"),
    ]
    static let bccCategories: [(key: String, label: String)] = [
        ("improv_core", "Improv Core"),
        ("sketch_core", "Sketch Core"),
        ("improv", "Improv"),
        ("sketch", "Sketch"),
        ("other", "Everything Else"),
    ]

    static func categories(for school: String) -> [(key: String, label: String)] {
        if school == bccSchool.id { return bccCategories }
        if ucbSchools.contains(where: { $0.id == school }) { return ucbCategories }
        return []
    }

    static func categoryKeys(for school: String) -> Set<String> {
        Set(categories(for: school).map(\.key))
    }

    static func defaultCategories(for school: String) -> Set<String> {
        categoryKeys(for: school).subtracting(coreCategoryKeys)
    }
}

struct ClassAlertPreferences: Codable, Equatable {
    static let currentVersion = 2
    var master = false
    /// Schools with a single school-wide subscription.
    var schools: Set<String> = []
    /// An absent key means Off; an empty set means On with no categories.
    /// The persisted name stays `ucb` so existing iCloud blobs and older builds
    /// preserve these selections, including BCC's new category subscriptions.
    var categorySelections: [String: Set<String>] = [:]
    var version = Self.currentVersion

    enum CodingKeys: String, CodingKey {
        case master, schools, version
        case categorySelections = "ucb"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent(Bool.self, forKey: .master) ?? false
        schools = try c.decodeIfPresent(Set<String>.self, forKey: .schools) ?? []
        categorySelections = try c.decodeIfPresent([String: Set<String>].self, forKey: .categorySelections) ?? [:]
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    @discardableResult
    mutating func migrateIfNeeded() -> Bool {
        let before = self
        // Before v1, clearing the last UCB category meant Off. Since v1 an
        // empty category set deliberately keeps the school enabled and silent.
        if version < 1 { categorySelections = categorySelections.filter { !$0.value.isEmpty } }
        // An older build can restore the school-wide BCC flag through iCloud
        // even when it retains our version number. Normalize it every time,
        // without overwriting an explicit category selection (including []).
        if schools.remove(ClassAlertCatalog.bccSchool.id) != nil,
           categorySelections[ClassAlertCatalog.bccSchool.id] == nil {
            categorySelections[ClassAlertCatalog.bccSchool.id] =
                ClassAlertCatalog.defaultCategories(for: ClassAlertCatalog.bccSchool.id)
        }
        version = max(version, Self.currentVersion)
        return self != before
    }

    mutating func setSchool(_ id: String, enabled: Bool) {
        if !ClassAlertCatalog.categories(for: id).isEmpty {
            setCategorizedSchool(id, enabled: enabled)
        } else if enabled {
            schools.insert(id)
        } else {
            schools.remove(id)
        }
    }

    mutating func setCategorizedSchool(_ id: String, enabled: Bool) {
        schools.remove(id)
        if enabled {
            if categorySelections[id] == nil {
                categorySelections[id] = ClassAlertCatalog.defaultCategories(for: id)
            }
        } else {
            categorySelections[id] = nil
        }
    }

    mutating func setCategory(_ id: String, category: String, enabled: Bool) {
        guard var selected = categorySelections[id] else { return }
        if enabled { selected.insert(category) } else { selected.remove(category) }
        categorySelections[id] = selected
    }

    mutating func setAllCategories(_ id: String, enabled: Bool) {
        guard let selected = categorySelections[id] else { return }
        // Preserve future keys learned through iCloud when selecting all.
        categorySelections[id] = enabled ? selected.union(ClassAlertCatalog.categoryKeys(for: id)) : []
    }

    func isCategorizedSchoolEnabled(_ id: String) -> Bool { categorySelections[id] != nil }

    var activeCount: Int {
        guard master else { return 0 }
        return schools.count + categorySelections.filter { !$0.value.isEmpty }.count
    }

    /// At most one subscription per school, never one per picked category —
    /// see `ClassAlertSubscription` for why. An enabled school with no picks
    /// plans nothing, which is what makes that state silent.
    var subscriptionPlan: [ClassAlertSubscription] {
        guard master else { return [] }
        var normalized = self
        normalized.migrateIfNeeded()
        let schoolWide = normalized.schools.map { ClassAlertSubscription(school: $0, categories: nil) }
        let categorized = normalized.categorySelections
            .filter { !$0.value.isEmpty }
            .map { ClassAlertSubscription(school: $0.key, categories: $0.value) }
        return (schoolWide + categorized).sorted { $0.id < $1.id }
    }
}

/// One CloudKit query subscription: school-wide (`alert/<school>/all`,
/// `school == X`) or, for a categorized school, ONE subscription covering
/// every pick (`alert/v3/<school>/<digest>`, `school == X AND ANY categories
/// IN picks`).
///
/// Why one per school: CloudKit sends a push for every subscription a new
/// record matches. The v2 plan had one subscription per picked category
/// (`categories CONTAINS c`), so a class tagged Stand-Up + Featured Programs +
/// Workshops pushed three times to anyone who picked all three. CloudKit
/// predicates have no OR, but `ANY categories IN picks` is sent as the
/// server's `listContainsAny` filter: the single subscription matches when
/// the class shares any pick, and fires once.
///
/// That query shape is new to the container. Like every earlier shape it had
/// to be learned in the development environment and deployed with the schema
/// to production before production would accept it (see CONTEXT.md,
/// "Production UCB subscription failure").
///
/// The digest is in the ID because the reconcile diffs by ID alone: a pick
/// change has to produce a new ID, so the old subscription (stale) is replaced
/// rather than left matching the previous picks. Sorting first makes it the
/// same on every device and launch whatever order the picks were made in.
struct ClassAlertSubscription: Identifiable, Equatable {
    let school: String
    /// Nil for a school-wide subscription; otherwise the picks, sorted.
    let categories: [String]?

    init(school: String, categories: Set<String>?) {
        self.school = school
        self.categories = categories?.sorted()
    }

    var id: String {
        if let categories { return "alert/v3/\(school)/\(Self.digest(categories))" }
        return "alert/\(school)/all"
    }

    var predicate: NSPredicate {
        if let categories {
            return NSPredicate(format: "school == %@ AND ANY categories IN %@", school, categories)
        }
        return NSPredicate(format: "school == %@", school)
    }

    /// 16 lowercase hex chars: FNV-1a 64-bit over the UTF-8 bytes of the
    /// sorted picks joined by ",". Hand-rolled because the logic harness
    /// compiles this file with plain `swiftc` (Foundation only, no CryptoKit),
    /// and Swift's `hashValue` is seeded per process, so it would change the
    /// ID on every launch. Not a security boundary — only a stable name.
    static func digest(_ sortedPicks: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sortedPicks.joined(separator: ",").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
