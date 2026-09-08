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
/// set), BCC daily with the same category bundles, and other schools daily
/// with one bundled record. Each device turns its
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

    // MARK: Preferences (persisted)
    private(set) var prefs = ClassAlertPreferences()
    /// The `classAlertPrefs` blob as we last read or wrote it. Anything else
    /// under that key was put there by iCloud — see `adoptExternalPrefs`.
    @ObservationIgnored private var persistedData: Data?
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
    /// True while a reconcile is owed: set on every pref change, cleared when
    /// one completes cleanly. Local only (not in `CloudSync.defaultsKeys`) —
    /// it is this device's debt — and it is what lets a switch-off that
    /// failed offline retry on a later launch even though master is now Off.
    private static let syncPendingKey = "classAlertSyncPending"

    /// Lazy on purpose: `CKContainer(identifier:)` traps when the build lacks
    /// the iCloud entitlement, and as a stored property that took the whole app
    /// down inside `UCBShowsApp.init()` rather than degrading class alerts.
    @ObservationIgnored
    private lazy var database = CKContainer(identifier: "iCloud.com.salimhafid.UCBShows").publicCloudDatabase

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.prefsKey) {
            persistedData = data
            if let saved = try? JSONDecoder().decode(ClassAlertPreferences.self, from: data) {
                prefs = saved
                migrateIfNeeded()
            }
        }
        // `CloudSync.applyExternal` writes another device's prefs straight
        // into UserDefaults, live. Adopt them, or the next local toggle
        // persists this device's stale copy over them and pushes that back
        // up, reverting the other device. Our own `persist` fires this too;
        // the data compare makes that a no-op.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptExternalPrefs() }
        }
        // Whichever feature obtained the grant, ours has to re-arm — matching
        // TicketStore and GoingStore. Without this, a user who granted via a
        // heart or a ticket left class alerts unregistered forever. With the
        // master switch Off there is nothing to arm, and the reconcile only
        // ever put an iCloud sign-in nag under an Off switch.
        NotificationCenter.default.addObserver(
            forName: NotificationAuth.didGrant, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.prefs.master else { return }
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

    /// Persist migrations and retain their reconcile debt even if master is
    /// Off. In particular, BCC's old school-wide subscription must be retired.
    private func migrateIfNeeded() {
        guard prefs.migrateIfNeeded() else { return }
        UserDefaults.standard.set(true, forKey: Self.syncPendingKey)
        persist()
    }

    /// Re-read prefs when the stored blob is not the one we last read or
    /// wrote — the only writer besides `persist` is iCloud, via `CloudSync`.
    private func adoptExternalPrefs() {
        let data = UserDefaults.standard.data(forKey: Self.prefsKey)
        guard data != persistedData else { return }
        persistedData = data
        guard let data, let saved = try? JSONDecoder().decode(ClassAlertPreferences.self, from: data),
              saved != prefs else { return }
        prefs = saved
        migrateIfNeeded()
        queueSync()
    }

    /// Count of schools currently alerting — drives the bell badge. Deliberately
    /// stricter than `isCategorizedSchoolEnabled`: this means "actually pushing", so a school
    /// that's on with no categories picked (which sends nothing) doesn't count.
    var activeCount: Int { prefs.activeCount }

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
        prefs.setSchool(id, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    func setCategorizedSchool(_ id: String, enabled: Bool) {
        prefs.setCategorizedSchool(id, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    func setCategory(_ id: String, category: String, enabled: Bool) {
        // Never materialize a key for an off school — under key-presence
        // semantics that would silently switch it on.
        guard prefs.isCategorizedSchoolEnabled(id) else { return }
        prefs.setCategory(id, category: category, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    /// Switch every category on, or clear them all while leaving the school on.
    func setAllCategories(_ id: String, enabled: Bool) {
        guard prefs.isCategorizedSchoolEnabled(id) else { return }
        prefs.setAllCategories(id, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    /// A key present means the school is on; the set says which categories.
    /// On-with-no-categories is a legal (silent) state, so
    /// unchecking the last category can't yank the school toggle out from under
    /// the user and disable the very rows they need to recover.
    func isCategorizedSchoolEnabled(_ id: String) -> Bool { prefs.isCategorizedSchoolEnabled(id) }

    private func persist() {
        if let data = try? JSONEncoder().encode(prefs) {
            // Recorded first: the write posts `didChangeNotification`, and
            // `adoptExternalPrefs` must see this blob as our own.
            persistedData = data
            UserDefaults.standard.set(data, forKey: Self.prefsKey)
        }
    }

    private func persistAndSync() {
        persist()
        queueSync()
    }

    /// A pref change owes a reconcile. Noted before the attempt, because the
    /// attempt can fail offline and the retry has to know it's owed.
    private func queueSync() {
        UserDefaults.standard.set(true, forKey: Self.syncPendingKey)
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
        guard prefs.master else {
            // Off can still owe a reconcile: a switch-off that failed offline
            // left every subscription live, and with master Off nothing else
            // retries. `desired` is empty, so this is only the delete.
            if UserDefaults.standard.bool(forKey: Self.syncPendingKey) {
                await syncSubscriptions()
            }
            return
        }
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
        guard prefs.master else {
            await armOnLaunch()   // the master-Off retry, nothing to prompt for
            return
        }
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
        Dictionary(uniqueKeysWithValues: prefs.subscriptionPlan.map { ($0.id, $0.predicate) })
    }

    /// Serialized: the reconcile is a read-modify-write (read `allSubscriptions`,
    /// diff, then `modifySubscriptions`) and `@MainActor` does not prevent
    /// reentrancy — each `await` is a suspension another caller walks straight
    /// into. Two overlapping runs diff against the same stale snapshot and race
    /// identical CloudKit writes and unordered `syncIssue` updates. `didGrant`
    /// fanning out alongside a `setMaster`/`armIfNeeded` call makes that a
    /// deterministic collision, not a rare one. A caller that coalesces gets
    /// its change reconciled all the same: `performSync` goes round again
    /// when `desired` moved under it.
    func syncSubscriptions() async {
        if let inFlight = syncTask { await inFlight.value; return }
        let task = Task { await performSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync() async {
        do {
            while true {
                let want = desired
                let existing = try await database.allSubscriptions()
                let ours = existing.filter { $0.subscriptionID.hasPrefix("alert/") }

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
                    let (saved, deleted) = try await database.modifySubscriptions(saving: new, deleting: stale)
                    // The call throws only for the operation as a whole. An
                    // item CloudKit rejected on its own (a predicate on a
                    // field the schema hasn't indexed, say) comes back per
                    // item, and swallowing it read as "healthy" over a
                    // subscription that never existed.
                    for case .failure(let error) in saved.values { throw error }
                    for case .failure(let error) in deleted.values { throw error }
                }
                // A toggle that landed during the awaits above only coalesced
                // onto this run; reconcile it now rather than at the next
                // foreground. IDs are deterministic, so keys are the diff.
                if Set(desired.keys) == Set(want.keys) { break }
            }
            syncIssue = ""
            UserDefaults.standard.set(false, forKey: Self.syncPendingKey)
        } catch let error as CKError where error.code == .notAuthenticated {
            syncIssue = "Sign in to iCloud (Settings) to receive class alerts."
        } catch {
            syncIssue = "Couldn’t update alert subscriptions — will retry. (\(error.localizedDescription))"
        }
    }
}
