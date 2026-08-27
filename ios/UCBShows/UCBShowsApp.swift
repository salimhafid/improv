import SwiftUI
import UIKit
import UserNotifications

/// The one thing SwiftUI's App lifecycle doesn't surface: whether APNs
/// registration actually succeeded. Class alerts are CloudKit pushes, so a
/// silent registration failure is indistinguishable from "notifications don't
/// work" — which is precisely how it presented. Nothing else lives here.
final class PushRegistrationDelegate: NSObject, UIApplicationDelegate {
    static let didRegister = Notification.Name("PushRegistration.didRegister")
    /// Object is the underlying `Error`.
    static let didFail = Notification.Name("PushRegistration.didFail")

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: Self.didRegister, object: nil)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: Self.didFail, object: error)
    }
}

@main
struct UCBShowsApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrationDelegate.self) private var pushDelegate
    @State private var store: ShowsStore
    @State private var classesStore: ClassesStore
    @State private var going: GoingStore
    @State private var talent: TalentStore
    @State private var app: AppState
    @State private var account: UCBAccountStore
    @State private var tickets: TicketStore
    @State private var classAlerts: ClassAlertsStore
    @Environment(\.scenePhase) private var scenePhase
    private let notifications = NotificationRouter()

    init() {
        // iCloud mirror first — a fresh install adopts the cloud copy of
        // settings/tickets, so every store below must read AFTER this.
        CloudSync.bootstrap()
        // Generous persistent cache so poster images load instantly on relaunch
        // (AsyncImage uses URLSession.shared → URLCache.shared).
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
        // Must be set BEFORE launch finishes or a notification tap that
        // cold-starts the app is dropped (the router buffers the tap until
        // onOpen is wired below).
        UNUserNotificationCenter.current().delegate = notifications
        _store = State(initialValue: ShowsStore())
        _classesStore = State(initialValue: ClassesStore())
        _going = State(initialValue: GoingStore())
        _talent = State(initialValue: TalentStore())
        _app = State(initialValue: AppState())
        _account = State(initialValue: UCBAccountStore())
        _tickets = State(initialValue: TicketStore())
        _classAlerts = State(initialValue: ClassAlertsStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(classesStore)
                .environment(going)
                .environment(talent)
                .environment(app)
                .environment(account)
                .environment(tickets)
                .environment(classAlerts)
                .tint(Theme.accent)
                .task {
                    // Wire the ticket feature once, then restore any UCB session
                    // with a SINGLE account read shared into the ticket store.
                    tickets.account = account
                    // One reminder per show: the ticket store tells the heart
                    // store which shows it already covers.
                    tickets.going = going
                    // The only source of show identity for a ticket the user
                    // already holds (bought on ucbtheatre.com, or restored from
                    // iCloud) — that identity is the dedupe key behind "exactly
                    // one reminder per show". The feed usually lands later, so
                    // `onChange` below closes the join from the other side.
                    tickets.shows = store
                    notifications.onOpen = { id in
                        app.openTicketID = id
                        app.activeTab = 1
                    }
                    notifications.onClassAlert = {
                        app.activeTab = 2
                    }
                    // Class alerts arrive as CloudKit pushes, so they need an
                    // APNs registration + a subscription reconcile on EVERY
                    // launch — the device token rotates, prefs can arrive from
                    // iCloud without this device ever flipping the switch, and
                    // a reconcile that failed offline has to get another go.
                    // Never prompts; see `armIfNeeded` for the asking path.
                    // Deliberately unstructured: the reconcile is a CloudKit
                    // round trip, and the session restore below must not queue
                    // behind it.
                    Task { await classAlerts.armOnLaunch() }
                    #if DEBUG
                    print("UCBShowsApp task: fakeTickets=\(DebugFixtures.fakeTickets) args=\(ProcessInfo.processInfo.arguments.count)")
                    // Invariant for any early return here: leave `account.phase`
                    // resolved. A stranded `.checking` is a permanent
                    // "Updating…" chip with no sign-out button. This one is
                    // safe — `DebugFixtures.seed` calls `debugForceSignedIn`.
                    if DebugFixtures.fakeTickets {
                        DebugFixtures.seed(account: account, tickets: tickets)
                        if DebugFixtures.stuckRestoring { account.debugForceChecking() }
                        return
                    }
                    if DebugFixtures.stuckRestoring {
                        account.debugForceChecking()
                        return
                    }
                    #endif
                    let outcome = await account.restoreOnLaunch()
                    tickets.adopt(outcome)
                }
                // The shows feed lands after the wallet does, so a ticket read
                // at launch had nothing to match against. Count, not contents:
                // a full array compare of ~2300 shows on every feed apply is
                // exactly the cost this is trying to avoid.
                .onChange(of: store.allShows.count) { _, _ in
                    tickets.backfillShowJoins()
                }
                // Periodic ticket/QR refresh: every foreground (throttled to
                // one sync per 5 minutes) keeps the locally stored QR current.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    if account.isSignedIn {
                        Task { await tickets.syncIfStale() }
                    }
                    // Covers a device token rotating and permission granted in
                    // Settings while we were backgrounded. Idempotent.
                    Task { await classAlerts.armOnLaunch() }
                }
        }
    }
}
