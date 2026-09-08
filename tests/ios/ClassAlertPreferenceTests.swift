import Foundation

private func alertPrefs(_ json: String) -> ClassAlertPreferences {
    try! JSONDecoder().decode(ClassAlertPreferences.self, from: Data(json.utf8))
}

func runClassAlertPreferenceTests() {
    let ucbDefaults: Set<String> = [
        "improv", "improv_electives", "sketch_character", "sketch_electives",
        "musical_improv", "standup", "clowning", "acting", "writing_programs",
        "featured_programs", "workshops", "intensives", "other",
    ]
    let bccDefaults: Set<String> = ["improv", "sketch", "other"]
    let cores: Set<String> = ["improv_core", "sketch_core"]
    for school in ClassAlertCatalog.ucbSchools {
        checkEqual(ClassAlertCatalog.defaultCategories(for: school.id), ucbDefaults,
                   "\(school.id) defaults retain all 13 non-core categories")
        checkEqual(ClassAlertCatalog.categoryKeys(for: school.id), ucbDefaults.union(cores),
                   "\(school.id) offers both core categories")
    }
    checkEqual(ClassAlertCatalog.defaultCategories(for: "brooklyn_cc"), bccDefaults,
               "BCC defaults cover improv, sketch, and everything else")
    checkEqual(ClassAlertCatalog.categoryKeys(for: "brooklyn_cc"), bccDefaults.union(cores),
               "BCC offers five categories")
    check(!ClassAlertCatalog.otherSchools.contains { $0.id == "brooklyn_cc" },
          "BCC appears only among category-controlled schools")

    var fresh = ClassAlertPreferences()
    check(!fresh.master && fresh.schools.isEmpty && fresh.categorySelections.isEmpty,
          "fresh preferences enable no alerts")
    for school in ClassAlertCatalog.ucbSchools {
        fresh.setCategorizedSchool(school.id, enabled: true)
        checkEqual(fresh.categorySelections[school.id], ucbDefaults,
                   "enabling \(school.id) uses the non-core defaults")
    }
    fresh.setSchool("brooklyn_cc", enabled: true)
    checkEqual(fresh.categorySelections["brooklyn_cc"], bccDefaults,
               "enabling BCC through the school API selects non-core categories")
    check(!fresh.schools.contains("brooklyn_cc"), "BCC never creates a school-wide preference")
    check(fresh.subscriptionPlan.isEmpty && fresh.activeCount == 0,
          "master Off suppresses the plan and badge without erasing selections")

    var legacy = alertPrefs(#"{"master":true,"schools":["brooklyn_cc","magnet"],"ucb":{"ucb_ny":["improv","workshops"],"ucb_la":[]}}"#)
    check(legacy.migrateIfNeeded(), "versionless preferences migrate")
    checkEqual(legacy.version, ClassAlertPreferences.currentVersion, "migration records the current version")
    checkEqual(legacy.categorySelections["ucb_ny"], ["improv", "workshops"],
               "migration preserves an explicit UCB selection without adding core or defaults")
    check(legacy.categorySelections["ucb_la"] == nil, "pre-v1 empty UCB selections remain Off")
    checkEqual(legacy.categorySelections["brooklyn_cc"], bccDefaults,
               "legacy enabled BCC migrates to non-core category defaults")
    checkEqual(legacy.schools, ["magnet"], "migration removes only BCC's school-wide flag")
    check(!legacy.migrateIfNeeded(), "a normalized preference is not migrated repeatedly")
    let migratedIDs = Set(legacy.subscriptionPlan.map(\.id))
    checkEqual(migratedIDs, ["alert/magnet/all", "alert/v2/ucb_ny/improv",
                            "alert/v2/ucb_ny/workshops", "alert/v2/brooklyn_cc/improv",
                            "alert/v2/brooklyn_cc/sketch", "alert/v2/brooklyn_cc/other"],
               "migration plans category subscriptions and retires legacy BCC's ID")
    checkEqual(legacy.activeCount, 3, "badge counts active schools rather than categories")

    var silent = alertPrefs(#"{"master":true,"schools":["brooklyn_cc"],"ucb":{"ucb_ny":[],"brooklyn_cc":[]},"version":1}"#)
    silent.migrateIfNeeded()
    check(silent.isCategorizedSchoolEnabled("ucb_ny") && silent.isCategorizedSchoolEnabled("brooklyn_cc"),
          "v1 explicit empty category sets remain enabled")
    checkEqual(silent.categorySelections["brooklyn_cc"], [],
               "an explicit silent BCC selection wins over its legacy school-wide flag")
    check(silent.subscriptionPlan.isEmpty && silent.activeCount == 0,
          "enabled schools with no selected categories send nothing")
    silent.setCategorizedSchool("brooklyn_cc", enabled: true)
    checkEqual(silent.categorySelections["brooklyn_cc"], [],
               "enabling an already enabled school never overwrites its empty selection")

    var off = alertPrefs(#"{"master":false,"schools":["brooklyn_cc"],"ucb":{"ucb_ny":["improv"]},"version":1}"#)
    off.migrateIfNeeded()
    check(!off.master && off.subscriptionPlan.isEmpty, "migration keeps master Off")
    checkEqual(off.categorySelections["brooklyn_cc"], bccDefaults,
               "master Off still retains BCC's migrated selection")
    var absent = alertPrefs(#"{"master":true,"schools":["magnet"],"version":1}"#)
    absent.migrateIfNeeded()
    check(!absent.isCategorizedSchoolEnabled("brooklyn_cc"), "migration never enables previously disabled BCC")

    var external = alertPrefs(#"{"master":true,"schools":["brooklyn_cc"],"ucb":{"ucb_ny":["improv_core","future_category"]},"version":7}"#)
    check(external.migrateIfNeeded(), "an old build's restored BCC flag is normalized even with a future version")
    checkEqual(external.version, 7, "migration never downgrades a newer preferences version")
    checkEqual(external.categorySelections["ucb_ny"], ["improv_core", "future_category"],
               "explicit core and future selections arriving through iCloud are preserved")
    let encoded = try! JSONEncoder().encode(external)
    let wire = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    check(wire["ucb"] != nil && wire["categorySelections"] == nil,
          "per-category preferences retain the existing iCloud wire key")
    let roundTrip = try! JSONDecoder().decode(ClassAlertPreferences.self, from: encoded)
    checkEqual(roundTrip, external, "iCloud encoding round-trips master, schools, categories, and version")

    var toggles = ClassAlertPreferences()
    toggles.master = true
    toggles.setCategory("brooklyn_cc", category: "improv_core", enabled: true)
    toggles.setAllCategories("brooklyn_cc", enabled: true)
    check(!toggles.isCategorizedSchoolEnabled("brooklyn_cc"),
          "category edits cannot silently enable an Off school")
    toggles.setCategorizedSchool("brooklyn_cc", enabled: true)
    toggles.setCategory("brooklyn_cc", category: "improv_core", enabled: true)
    checkEqual(toggles.categorySelections["brooklyn_cc"], bccDefaults.union(["improv_core"]),
               "core classes can be explicitly opted into")
    toggles.setCategory("brooklyn_cc", category: "future_category", enabled: true)
    toggles.setAllCategories("brooklyn_cc", enabled: true)
    checkEqual(toggles.categorySelections["brooklyn_cc"], bccDefaults.union(cores).union(["future_category"]),
               "Select all includes core and preserves future category keys")
    toggles.setAllCategories("brooklyn_cc", enabled: false)
    check(toggles.isCategorizedSchoolEnabled("brooklyn_cc") && toggles.subscriptionPlan.isEmpty,
          "Clear all leaves the school enabled but silent")
    toggles.setCategory("brooklyn_cc", category: "sketch", enabled: true)
    toggles.setCategory("brooklyn_cc", category: "sketch", enabled: false)
    checkEqual(toggles.categorySelections["brooklyn_cc"], [], "clearing the last category preserves the empty set")
    toggles.setSchool("brooklyn_cc", enabled: false)
    check(!toggles.isCategorizedSchoolEnabled("brooklyn_cc"), "switching a categorized school Off removes its key")
    toggles.setSchool("brooklyn_cc", enabled: true)
    checkEqual(toggles.categorySelections["brooklyn_cc"], bccDefaults,
               "re-enabling a school starts with the new non-core defaults")
    toggles.setSchool("magnet", enabled: true)
    toggles.setSchool("magnet", enabled: false)
    check(!toggles.schools.contains("magnet"), "ordinary school toggle behavior is unchanged")

    let defaults = toggles.subscriptionPlan
    let coreRecord: [String: Any] = ["school": "brooklyn_cc", "categories": ["improv_core"]]
    let improvRecord: [String: Any] = ["school": "brooklyn_cc", "categories": ["improv"]]
    check(!defaults.contains { $0.predicate.evaluate(with: coreRecord) },
          "default BCC subscriptions exclude exclusively tagged core records")
    check(defaults.contains { $0.predicate.evaluate(with: improvRecord) },
          "default BCC subscriptions include non-core improv")
    let core = ClassAlertSubscription(school: "brooklyn_cc", category: "improv_core")
    checkEqual(core.id, "alert/v2/brooklyn_cc/improv_core", "core subscription uses the established v2 namespace")
    check(core.predicate.evaluate(with: coreRecord) && !core.predicate.evaluate(with: improvRecord),
          "core subscription uses list membership rather than the broader category")
    check(!core.predicate.evaluate(with: ["school": "ucb_ny", "categories": ["improv_core"]]),
          "category predicates remain scoped to their school")
    let schoolWide = ClassAlertSubscription(school: "magnet", category: nil)
    check(schoolWide.predicate.evaluate(with: ["school": "magnet"]) &&
          !schoolWide.predicate.evaluate(with: ["school": "brooklyn_cc"]),
          "ordinary school subscriptions still require only the school")
}
