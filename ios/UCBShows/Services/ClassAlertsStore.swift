import CloudKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Class-alert preferences + the CloudKit subscriptions that make them real.
///
/// The GitHub Actions watcher (watcher.py) writes a `ClassAlert` record to the
/// app's public CloudKit database whenever a school posts new classes — UCB
/// checked on a schedule (one record per bundle of classes sharing a category
/// set), every other school daily (one bundled record). Each device turns its
/// toggles into `CKQuerySubscription`s, so Apple's push infrastructure
/// delivers exactly the alerts this user asked for — no server of ours involved.
///
/// A UCB record carries every category its classes belong to, and a
/// subscription matches if ANY of them is one the user picked — a Kevin
/// McDonald workshop tagged Improv Electives + Sketch Electives + Featured
/// Programs reaches all three audiences. Subscription IDs are deterministic
/// ("alert/v2/<school>/<category>") so the desired set can be reconciled
/// against CloudKit's on every change; the "v2" retires the first-generation
/// IDs, whose `category ==` predicate only ever saw a class's primary tag.
@MainActor
@Observable
final class ClassAlertsStore {

    struct School: Identifiable {
        let id: String
        let name: String
        let city: String
    }

    /// UCB rows (customizable, per-category).
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

    /// Categories switched on when a UCB school is first enabled: the core
    /// improv track, its electives, and the marquee Featured Programs — the
    /// last two are where one-off workshops with visiting names land, and
    /// "Improv only" silently dropped exactly those. Everything else is opt-in
    /// (use "Select all" in the detail view to take the lot).
    static let defaultUCBCategories: Set<String> = ["improv", "improv_electives", "featured_programs"]

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
    /// In-flight reconcile, so overlapping callers coalesce onto one run.
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// The user turned notifications off for the app, so alerts are switched on
    /// and going nowhere. Surfaced in the sheet with a route to Settings.
    private(set) var authorizationDenied = false
    /// Raised when the user switches something on while notifications are
    /// denied. The footer states the condition, but a switch that flips green
    /// and can never deliver needs saying at the moment of the tap — and the
    /// per-school toggles live on a screen the footer isn't even on.
    var deniedPromptVisible = false
    /// Last APNs registration failure ("" = fine). Kept apart from `syncIssue`
    /// so a successful subscription reconcile doesn't erase it — the two fail
    /// independently, and a device with no push token receives nothing however
    /// healthy its subscriptions look.
    private(set) var registrationIssue = ""

    private static let prefsKey = "classAlertPrefs"

    /// Lazy on purpose: `CKContainer(identifier:)` traps when the build lacks
    /// the iCloud entitlement, and as a stored property that took the whole app
    /// down inside `UCBShowsApp.init()` rather than degrading class alerts.
    @ObservationIgnored
    private lazy var database = CKContainer(identifier: "iCloud.com.salimhafid.UCBShows").publicCloudDatabase

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.prefsKey),
           let saved = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = saved
            migrateIfNeeded()
        }
        // Whichever feature obtained the grant, ours has to re-arm — matching
        // TicketStore and GoingStore. Without this, a user who granted via a
        // heart or a ticket left class alerts unregistered forever.
        NotificationCenter.default.addObserver(
            forName: NotificationAuth.didGrant, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.authorizationDenied = false
                UIApplication.shared.registerForRemoteNotifications()
                Task { await self.syncSubscriptions() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: PushRegistrationDelegate.didRegister, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registrationIssue = "" }
        }
        NotificationCenter.default.addObserver(
            forName: PushRegistrationDelegate.didFail, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.object as? Error)?.localizedDescription ?? "unknown error"
            MainActor.assumeIsolated {
                self?.registrationIssue = "Couldn’t register for push notifications. (\(reason))"
            }
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
        if on {
            // The ask and the subscribe are independent: a declined prompt
            // still leaves the subscriptions correct for a later grant.
            Task {
                if await promptIfAlreadyDenied() { return }
                await requestPushAuthorization()
            }
        } else {
            authorizationDenied = false
            deniedPromptVisible = false
        }
        persistAndSync()
    }

    func setSchool(_ id: String, enabled: Bool) {
        if enabled { prefs.schools.insert(id) } else { prefs.schools.remove(id) }
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    func setUCB(_ id: String, enabled: Bool) {
        if enabled {
            // Only seed a school that has no entry at all — an existing pick
            // (including the deliberate on-with-nothing state) is never rewritten.
            if prefs.ucb[id] == nil { prefs.ucb[id] = Self.defaultUCBCategories }
            Task { await promptIfAlreadyDenied() }
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
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    /// Switch every category on, or clear them all while leaving the school on.
    func setAllUCBCategories(_ id: String, enabled: Bool) {
        guard prefs.ucb[id] != nil else { return }
        prefs.ucb[id] = enabled ? Set(Self.ucbCategories.map(\.key)) : []
        if enabled { Task { await promptIfAlreadyDenied() } }
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

    // MARK: Arming (permission + APNs registration)

    /// Every "switch this on" gesture routes through here. Only fires when the
    /// refusal is ALREADY on record: declining the system prompt seconds
    /// earlier is not a moment to stack a second dialog on top of, and the
    /// footer covers that case.
    @discardableResult
    private func promptIfAlreadyDenied() async -> Bool {
        guard await NotificationAuth.status() == .denied else { return false }
        authorizationDenied = true
        deniedPromptVisible = true
        return true
    }

    /// Prompt, then register — the toggle is the notifiable moment. Honors the
    /// answer: registering after a "Don't Allow" achieves nothing, and the
    /// switch has to stop claiming otherwise.
    private func requestPushAuthorization() async {
        let granted = await NotificationAuth.ensure()
        authorizationDenied = !granted
        guard granted else { return }
        // APNs registration is specific to class alerts: these arrive as
        // CloudKit pushes, unlike the on-device ticket/show reminders.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Silent re-arm, for launch and every foreground. NEVER prompts — that
    /// would be the contextless ask `NotificationAuth` exists to prevent.
    ///
    /// This is what makes class alerts work at all on a device that never
    /// flipped the switch itself: `classAlertPrefs` rides iCloud, so a fresh
    /// install or a second device comes up with the master switch already ON,
    /// and nothing here used to run. Apple also documents registering on every
    /// launch, because the device token rotates.
    func armOnLaunch() async {
        guard prefs.master else { return }
        switch await NotificationAuth.status() {
        case .denied:
            authorizationDenied = true
        case .notDetermined:
            // Not our moment to ask — `armIfNeeded` handles it when the user
            // opens the sheet.
            break
        default:
            authorizationDenied = false
            UIApplication.shared.registerForRemoteNotifications()
            // Idempotent (it diffs against CloudKit's own list), and the only
            // thing that ever retries a reconcile that failed offline.
            await syncSubscriptions()
        }
    }

    /// Arm from the Class Alerts sheet, prompting if we've never asked. Opening
    /// this screen with alerts already on IS a notifiable moment, and it's the
    /// only one a user whose prefs arrived from iCloud will ever reach — they
    /// never touch the toggle, so `setMaster` never fires.
    func armIfNeeded() async {
        guard prefs.master else { return }
        guard await NotificationAuth.status() == .notDetermined else {
            await armOnLaunch()
            return
        }
        await requestPushAuthorization()
        await syncSubscriptions()
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
                // CONTAINS on a list field is CloudKit's documented membership
                // test ("favoriteColors CONTAINS 'red'"). The record also still
                // carries a scalar `category`, but matching on it would recreate
                // the one-tag-per-class bug this replaces.
                out["alert/v2/\(school)/\(category)"] =
                    NSPredicate(format: "school == %@ AND categories CONTAINS %@", school, category)
            }
        }
        return out
    }

    /// Serialized: the reconcile is a read-modify-write (read `allSubscriptions`,
    /// diff, then `modifySubscriptions`) and `@MainActor` does not prevent
    /// reentrancy — each `await` is a suspension another caller walks straight
    /// into. Two overlapping runs diff against the same stale snapshot and race
    /// identical CloudKit writes and unordered `syncIssue` updates. `didGrant`
    /// fanning out alongside a `setMaster`/`armIfNeeded` call makes that a
    /// deterministic collision, not a rare one.
    func syncSubscriptions() async {
        if let inFlight = syncTask { await inFlight.value; return }
        let task = Task { await performSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync() async {
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
