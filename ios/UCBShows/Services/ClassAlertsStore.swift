import CloudKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Class-alert preferences + the CloudKit subscriptions that make them real.
///
/// The GitHub Actions watcher (watcher.py) writes a `ClassAlert` record to the
/// app's public CloudKit database whenever a school posts new classes — one
/// record per new class (a capped summary record when a school posts a flood
/// at once), UCB checked every couple of minutes and the other schools about
/// daily. Each device turns its
/// toggles into `CKQuerySubscription`s, so Apple's push infrastructure
/// delivers exactly the alerts this user asked for — no server of ours involved.
///
/// A UCB record carries every category its classes belong to, and a
/// subscription matches if ANY of them is one the user picked — a Kevin
/// McDonald workshop tagged Improv Electives + Sketch Electives + Featured
/// Programs reaches all three audiences, and someone who picked all three
/// hears it once. That is why a categorized school gets ONE subscription for
/// all its picks ("alert/v3/<school>/<digest of the picks>", `ANY categories
/// IN picks`) — CloudKit pushes once per matching subscription, so the
/// per-category "alert/v2/<school>/<category>" IDs pushed once per pick a
/// class carried. IDs are deterministic so the desired set can be reconciled
/// against CloudKit's on every change. Retired generations — v2, and the
/// first-generation `category ==` IDs that only ever saw a class's primary
/// tag — still start with "alert/", so the reconcile deletes them as stale.
///
/// From 1.8 alerts are an in-app purchase, and `access` gates them. Unlocked
/// (bought; grandfathered because the first install predates the paywall
/// build; or a TestFlight build while the remote free flag is on) plans the
/// prefs as before. Locked deletes every "alert/" subscription only to take
/// back what this install subscribed under an unlock that can end (a refund,
/// the TestFlight flag turned off), and then only once; otherwise it leaves
/// them alone. Subscriptions belong to the iCloud account, and TestFlight
/// shares production CloudKit with the App Store, so a locked TestFlight build
/// that deleted them would silence a paying or grandfathered device on the same
/// account. Unknown (StoreKit can't answer yet, e.g. an offline first launch)
/// touches nothing and keeps the reconcile owed: deleting on a guess would
/// silence a paying user who is merely offline. The paywall never edits
/// `prefs` — they ride iCloud to the user's other devices — it only stops
/// them taking effect.
@MainActor
@Observable
final class ClassAlertsStore {

    /// The purchase gate, set once at launch (see `desired`). Observed, not
    /// ignored: the bell may render before the app wires it, and setting it
    /// is what makes that view start tracking the gate's state.
    var access: ClassAlertsAccess?
    /// Definitively locked. Unknown is not locked: until StoreKit answers,
    /// the badge and switches go on reading the saved prefs.
    private var isLocked: Bool { access?.isLocked ?? false }

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
    /// What this device actually permits, independently of iCloud preferences
    /// and successful push registration. Nil until the first settings read.
    private(set) var deliveryStatus: NotificationDeliveryStatus?
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
    /// True once this install has subscribed under an unlock a later lock can
    /// end (a purchase, which can be refunded, or the TestFlight flag); cleared
    /// when that lock's delete completes. Local only for the same reason as
    /// the pending flag. Grandfathering never sets it: it is permanent in
    /// production, so a lock that follows it means a TestFlight build was
    /// installed over the App Store one, and other devices' subscriptions are
    /// not this install's to delete.
    private static let revokeOnLockKey = "classAlertsRevokeOnLock"

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
        // master switch Off (or alerts locked behind the purchase) there is
        // nothing to arm, and the reconcile only ever put an iCloud sign-in
        // nag under an Off switch.
        NotificationCenter.default.addObserver(
            forName: NotificationAuth.didGrant, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.prefs.master, !self.isLocked else { return }
                self.authorizationDenied = false
                UIApplication.shared.registerForRemoteNotifications()
                Task {
                    await self.refreshDeliveryStatus()
                    await self.syncSubscriptions()
                }
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
    /// Zero while locked: this install isn't keeping any subscription for them.
    var activeCount: Int { isLocked ? 0 : prefs.activeCount }

    /// The paywall's answer moved (bought, refunded, restored, grandfathering
    /// settled, the TestFlight flag flipped). Owes a reconcile like a pref
    /// change: unlocking subscribes the saved picks, and locking takes back
    /// what this install's own unlock subscribed (see `desired`).
    /// With master Off the plan is empty whatever the answer, so only a debt
    /// already on record is worth the CloudKit trip — an Off device stays off
    /// CloudKit at launch, as before.
    func accessChanged() {
        guard prefs.master || UserDefaults.standard.bool(forKey: Self.syncPendingKey) else { return }
        queueSync()
        // An unlock outside the sheet (Ask to Buy approved, a purchase on
        // another device, the TestFlight flag turned on) also has to register
        // this device, because `armOnLaunch` skips that while locked. Without
        // it the subscriptions exist and no push reaches this device until the
        // next foreground. It never prompts; its reconcile coalesces with the
        // one just queued.
        if prefs.master, access?.isUnlocked == true {
            Task { await armOnLaunch() }
        }
    }

    // MARK: Toggles (each persists + resyncs)
    // Switching something on is what the purchase buys, so it is a no-op
    // while locked (the sheet disables those controls too). Switching off
    // always works.

    func setMaster(_ on: Bool) {
        if on && isLocked { return }
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
        if enabled && isLocked { return }
        prefs.setSchool(id, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    func setCategorizedSchool(_ id: String, enabled: Bool) {
        if enabled && isLocked { return }
        prefs.setCategorizedSchool(id, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    func setCategory(_ id: String, category: String, enabled: Bool) {
        // Never materialize a key for an off school — under key-presence
        // semantics that would silently switch it on.
        guard prefs.isCategorizedSchoolEnabled(id), !(enabled && isLocked) else { return }
        prefs.setCategory(id, category: category, enabled: enabled)
        if enabled { Task { await promptIfAlreadyDenied() } }
        persistAndSync()
    }

    /// Switch every category on, or clear them all while leaving the school on.
    func setAllCategories(_ id: String, enabled: Bool) {
        guard prefs.isCategorizedSchoolEnabled(id), !(enabled && isLocked) else { return }
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
        await refreshDeliveryStatus()
        guard authorizationDenied else { return false }
        deniedPromptVisible = true
        return true
    }

    private func refreshDeliveryStatus() async {
        let status = await NotificationAuth.deliveryStatus()
        deliveryStatus = status
        authorizationDenied = prefs.master && status.authorization == .denied
    }

    /// Prompt, then register — the toggle is the notifiable moment. Honors the
    /// answer: registering after a "Don't Allow" achieves nothing, and the
    /// switch has to stop claiming otherwise.
    private func requestPushAuthorization() async {
        let granted = await NotificationAuth.ensure()
        await refreshDeliveryStatus()
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
        await refreshDeliveryStatus()
        guard prefs.master, !isLocked else {
            // Off can still owe a reconcile: a switch-off that failed offline
            // left every subscription live, and with master Off nothing else
            // retries. `desired` is empty, so this is only the delete. Locked
            // is the same — nothing to register for, but a refund's delete
            // that failed offline is owed.
            if UserDefaults.standard.bool(forKey: Self.syncPendingKey) {
                await syncSubscriptions()
            }
            return
        }
        switch deliveryStatus?.authorization {
        case .denied:
            authorizationDenied = true
        case .notDetermined, nil:
            // Not our moment to ask — `armIfNeeded` handles it when the user
            // opens the sheet.
            break
        case .allowed, .provisional:
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
        guard prefs.master, !isLocked else {
            await armOnLaunch()   // the Off/locked retry, nothing to prompt for
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

    /// Desired subscription IDs, or nil for "don't reconcile" — the one place
    /// the purchase gate meets CloudKit. Unlocked: the prefs' plan. Locked:
    /// none, so every "alert/" subscription goes, but only while this install
    /// owes that revoke (`revokeOnLockKey`: a refund, or the TestFlight flag
    /// turned off). A locked install that never subscribed under such an
    /// unlock gets nil instead: those subscriptions belong to another device
    /// on the account. Unknown, or the gate not wired yet: nil, and nothing is
    /// created or deleted until the answer arrives (`accessChanged` queues
    /// that reconcile).
    private var desired: [String: NSPredicate]? {
        switch access?.state {
        case .unlocked:
            return Dictionary(uniqueKeysWithValues: prefs.subscriptionPlan.map { ($0.id, $0.predicate) })
        case .locked:
            return UserDefaults.standard.bool(forKey: Self.revokeOnLockKey) ? [:] : nil
        case .unknown, nil:
            return nil
        }
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
    ///
    /// While `desired` is nil (the purchase gate undecided, or locked with
    /// nothing of this install's to take back) this returns without touching
    /// CloudKit or the pending flag, so the debt survives for the reconcile
    /// `accessChanged` queues once the answer changes.
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
                // Nothing to reconcile (undecided, or locked with no revoke
                // owed), at the start or after a round whose awaits it moved
                // under. Return before the flag is cleared.
                guard let want = desired else { return }
                // Recorded before any write, so a run that fails partway
                // still leaves a refund owing the delete.
                if case .unlocked(let reason)? = access?.state, reason != .grandfathered {
                    UserDefaults.standard.set(true, forKey: Self.revokeOnLockKey)
                }
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
                // Save first, delete only once every save succeeded — two
                // calls, not one. If production rejects a new subscription
                // (a query shape its schema hasn't learned — each new shape,
                // v3's `ANY categories IN` included, needs a schema deploy),
                // deleting the old ones in the same call would leave the user
                // with no alerts at all. Keeping them means duplicate pushes
                // at worst until a later reconcile succeeds; the dirty flag
                // stays set, so the next launch or foreground retries.
                //
                // Each call throws only for the operation as a whole. An
                // item CloudKit rejected on its own (a predicate on a field
                // the schema hasn't indexed, say) comes back per item, and
                // swallowing it read as "healthy" over a subscription that
                // never existed.
                if !new.isEmpty {
                    let (saved, _) = try await database.modifySubscriptions(saving: new, deleting: [])
                    for case .failure(let error) in saved.values { throw error }
                }
                if !stale.isEmpty {
                    let (_, deleted) = try await database.modifySubscriptions(saving: [], deleting: stale)
                    for case .failure(let error) in deleted.values { throw error }
                }
                // A toggle (or a purchase-gate change) that landed during the
                // awaits above only coalesced onto this run; reconcile it now
                // rather than at the next foreground. IDs are deterministic,
                // so keys are the diff. A gate gone undecided (nil) goes round
                // to the guard above.
                if let now = desired, Set(now.keys) == Set(want.keys) { break }
            }
            syncIssue = ""
            UserDefaults.standard.set(false, forKey: Self.syncPendingKey)
            // The lock's delete went through. Later locked launches hold, or
            // a TestFlight build would delete on every launch what an App
            // Store device on the account keeps recreating.
            if isLocked { UserDefaults.standard.removeObject(forKey: Self.revokeOnLockKey) }
        } catch let error as CKError where error.code == .notAuthenticated {
            syncIssue = "Sign in to iCloud (Settings) to receive class alerts."
        } catch {
            syncIssue = "Couldn’t update alert subscriptions — will retry. (\(error.localizedDescription))"
        }
    }
}
