import CloudKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Class-alert preferences + the CloudKit subscriptions that make them real.
///
/// The GitHub Actions watcher (watcher.py) writes a `ClassAlert` record to the
/// app's public CloudKit database whenever a school posts new classes — UCB
/// checked every 10 minutes (one record per category), every other school
/// daily (one bundled record). Each device turns its toggles into
/// `CKQuerySubscription`s, so Apple's push infrastructure delivers exactly the
/// alerts this user asked for — no server of ours involved.
///
/// Subscription IDs are deterministic ("alert/<school>/<category>") so the
/// desired set can be reconciled against CloudKit's on every change.
@MainActor
@Observable
final class ClassAlertsStore {

    struct School: Identifiable {
        let id: String
        let name: String
        let city: String
    }

    /// UCB rows (customizable, checked every 10 minutes).
    static let ucbSchools: [School] = [
        School(id: "ucb_ny", name: "UCB New York", city: "New York"),
        School(id: "ucb_la", name: "UCB Los Angeles", city: "Los Angeles"),
        School(id: "ucb_online", name: "UCB Online", city: "Online"),
    ]

    /// Everyone else (simple on/off, checked daily).
    static let otherSchools: [School] = [
        School(id: "magnet", name: "Magnet Theater", city: "New York"),
        School(id: "brooklyn_cc", name: "Brooklyn Comedy Collective", city: "New York"),
        School(id: "wgis_ny", name: "WGIS New York", city: "New York"),
        School(id: "wgis_la", name: "WGIS Los Angeles", city: "Los Angeles"),
        School(id: "annoyance", name: "The Annoyance", city: "Chicago"),
        School(id: "io_chicago", name: "iO Theater", city: "Chicago"),
        School(id: "second_city", name: "The Second City", city: "Chicago"),
        School(id: "logan_square", name: "Logan Square Improv", city: "Chicago"),
    ]

    /// Category keys mirror watcher.py's Arlo-tag mapping.
    static let ucbCategories: [(key: String, label: String)] = [
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

    /// Categories switched on when a UCB school is first enabled — deliberately
    /// just the core improv track. Everything else is opt-in (use "Select all"
    /// in the detail view to take the lot).
    static let defaultUCBCategories: Set<String> = ["improv"]

    // MARK: Preferences (persisted)

    struct Prefs: Codable, Equatable {
        var master = false
        /// Enabled non-UCB school ids.
        var schools: Set<String> = []
        /// UCB school id → enabled category keys. A key present with an empty
        /// set means "on, but no categories" (sends nothing).
        var ucb: [String: Set<String>] = [:]
        /// Schema version, so a one-time migration can run without re-running
        /// on every launch. Absent (0) = written before key-presence semantics.
        var version = 0
    }

    /// Current `Prefs` schema version. v1 introduced key-presence semantics for
    /// `ucb` (see `isUCBEnabled`).
    private static let prefsVersion = 1

    private(set) var prefs = Prefs()
    /// Human-readable status of the last subscription sync ("" = fine).
    private(set) var syncIssue = ""

    private static let prefsKey = "classAlertPrefs"
    private let database = CKContainer(identifier: "iCloud.com.salimhafid.UCBShows").publicCloudDatabase

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.prefsKey),
           let saved = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = saved
            migrateIfNeeded()
        }
    }

    /// Pre-v1, a school was "on" only while its category set was non-empty, so
    /// unchecking the last category was how you silenced it — leaving an empty
    /// set behind. Key-presence semantics would read those as on again, so drop
    /// them once. After v1 an empty set is a deliberate (silent) state and is
    /// left alone.
    private func migrateIfNeeded() {
        guard prefs.version < 1 else { return }
        prefs.ucb = prefs.ucb.filter { !$0.value.isEmpty }
        prefs.version = Self.prefsVersion
        persist()
    }

    /// Count of schools currently alerting — drives the bell badge. Deliberately
    /// stricter than `isUCBEnabled`: this means "actually pushing", so a school
    /// that's on with no categories picked (which sends nothing) doesn't count.
    var activeCount: Int {
        guard prefs.master else { return 0 }
        return prefs.schools.count + prefs.ucb.filter { !$0.value.isEmpty }.count
    }

    // MARK: Toggles (each persists + resyncs)

    func setMaster(_ on: Bool) {
        prefs.master = on
        if on { requestPushAuthorization() }
        persistAndSync()
    }

    func setSchool(_ id: String, enabled: Bool) {
        if enabled { prefs.schools.insert(id) } else { prefs.schools.remove(id) }
        persistAndSync()
    }

    func setUCB(_ id: String, enabled: Bool) {
        if enabled {
            // Only seed a school that has no entry at all — an existing pick
            // (including the deliberate on-with-nothing state) is never rewritten.
            if prefs.ucb[id] == nil { prefs.ucb[id] = Self.defaultUCBCategories }
        } else {
            prefs.ucb[id] = nil
        }
        persistAndSync()
    }

    func setUCBCategory(_ id: String, category: String, enabled: Bool) {
        // Never materialize a key for an off school — under key-presence
        // semantics that would silently switch it on.
        guard var set = prefs.ucb[id] else { return }
        if enabled { set.insert(category) } else { set.remove(category) }
        prefs.ucb[id] = set
        persistAndSync()
    }

    /// Switch every category on, or clear them all while leaving the school on.
    func setAllUCBCategories(_ id: String, enabled: Bool) {
        guard prefs.ucb[id] != nil else { return }
        prefs.ucb[id] = enabled ? Set(Self.ucbCategories.map(\.key)) : []
        persistAndSync()
    }

    /// A key present means the school is on; the set says which categories.
    /// On-with-no-categories is a legal (silent) state — see `Prefs.ucb` — so
    /// unchecking the last category can't yank the school toggle out from under
    /// the user and disable the very rows they need to recover.
    func isUCBEnabled(_ id: String) -> Bool { prefs.ucb[id] != nil }

    private func persist() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.prefsKey)
        }
    }

    private func persistAndSync() {
        persist()
        Task { await syncSubscriptions() }
    }

    private func requestPushAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: CloudKit subscription reconcile

    /// Desired subscription IDs for the current prefs.
    private var desired: [String: NSPredicate] {
        guard prefs.master else { return [:] }
        var out: [String: NSPredicate] = [:]
        for id in prefs.schools {
            out["alert/\(id)/all"] = NSPredicate(format: "school == %@", id)
        }
        for (school, categories) in prefs.ucb {
            for category in categories {
                out["alert/\(school)/\(category)"] =
                    NSPredicate(format: "school == %@ AND category == %@", school, category)
            }
        }
        return out
    }

    func syncSubscriptions() async {
        do {
            let existing = try await database.allSubscriptions()
            let ours = existing.filter { $0.subscriptionID.hasPrefix("alert/") }
            let want = desired

            let stale = ours.map(\.subscriptionID).filter { want[$0] == nil }
            let missing = want.filter { id, _ in !ours.contains { $0.subscriptionID == id } }

            var new: [CKSubscription] = []
            for (id, predicate) in missing {
                let sub = CKQuerySubscription(recordType: "ClassAlert", predicate: predicate,
                                              subscriptionID: id, options: .firesOnRecordCreation)
                let info = CKSubscription.NotificationInfo()
                // Title/body come straight from the watcher-composed record.
                info.titleLocalizationKey = "CA_TITLE"
                info.titleLocalizationArgs = ["pushTitle"]
                info.alertLocalizationKey = "CA_BODY"
                info.alertLocalizationArgs = ["pushBody"]
                info.soundName = "default"
                sub.notificationInfo = info
                new.append(sub)
            }
            if !new.isEmpty || !stale.isEmpty {
                _ = try await database.modifySubscriptions(saving: new, deleting: stale)
            }
            syncIssue = ""
        } catch let error as CKError where error.code == .notAuthenticated {
            syncIssue = "Sign in to iCloud (Settings) to receive class alerts."
        } catch {
            syncIssue = "Couldn’t update alert subscriptions — will retry. (\(error.localizedDescription))"
        }
    }
}
