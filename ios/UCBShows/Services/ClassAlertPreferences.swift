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

    var subscriptionPlan: [ClassAlertSubscription] {
        guard master else { return [] }
        var normalized = self
        normalized.migrateIfNeeded()
        let schoolWide = normalized.schools.map { ClassAlertSubscription(school: $0, category: nil) }
        let categorized = normalized.categorySelections.flatMap { school, categories in
            categories.map { ClassAlertSubscription(school: school, category: $0) }
        }
        return (schoolWide + categorized).sorted { $0.id < $1.id }
    }
}

/// Uses the existing school-only and school + categories CONTAINS templates.
/// New category values do not introduce a new CloudKit query shape.
struct ClassAlertSubscription: Identifiable, Equatable {
    let school: String
    let category: String?

    var id: String {
        if let category { return "alert/v2/\(school)/\(category)" }
        return "alert/\(school)/all"
    }

    var predicate: NSPredicate {
        if let category {
            return NSPredicate(format: "school == %@ AND categories CONTAINS %@", school, category)
        }
        return NSPredicate(format: "school == %@", school)
    }
}
