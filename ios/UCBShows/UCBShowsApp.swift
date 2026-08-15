import SwiftUI
import UserNotifications

@main
struct UCBShowsApp: App {
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
                    notifications.onOpen = { id in
                        app.openTicketID = id
                        app.activeTab = 1
                    }
                    notifications.onClassAlert = {
                        app.activeTab = 2
                    }
                    #if DEBUG
                    print("UCBShowsApp task: fakeTickets=\(DebugFixtures.fakeTickets) args=\(ProcessInfo.processInfo.arguments.count)")
                    if DebugFixtures.fakeTickets {
                        DebugFixtures.seed(account: account, tickets: tickets)
                        return
                    }
                    #endif
                    let outcome = await account.restoreOnLaunch()
                    tickets.adopt(outcome)
                }
                // Periodic ticket/QR refresh: every foreground (throttled to
                // one sync per 5 minutes) keeps the locally stored QR current.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, account.isSignedIn {
                        Task { await tickets.syncIfStale() }
                    }
                }
        }
    }
}
