import SwiftUI
import UserNotifications

@main
struct UCBShowsApp: App {
    @State private var store = ShowsStore()
    @State private var classesStore = ClassesStore()
    @State private var going = GoingStore()
    @State private var talent = TalentStore()
    @State private var app = AppState()
    @State private var account = UCBAccountStore()
    @State private var tickets = TicketStore()
    private let notifications = NotificationRouter()

    init() {
        // Generous persistent cache so poster images load instantly on relaunch
        // (AsyncImage uses URLSession.shared → URLCache.shared).
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
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
                .tint(Theme.accent)
                .task {
                    // Wire the ticket feature once, then restore any UCB session.
                    tickets.account = account
                    notifications.onOpen = { id in
                        app.openTicketID = id
                        app.activeTab = 3
                    }
                    UNUserNotificationCenter.current().delegate = notifications
                    await account.restoreOnLaunch()
                    if account.isSignedIn { await tickets.sync() }
                }
        }
    }
}
