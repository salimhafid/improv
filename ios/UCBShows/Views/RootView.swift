import SwiftUI

/// Three-tab shell: Shows, Classes, and Tickets (which also holds the hearted
/// "I'm Going" shows) — Shows and Classes are scoped to
/// the theater chosen in the left sidebar. On iPhone the sidebar is a drawer
/// overlaying the TabView (opened from each tab's hamburger button); on iPad
/// (regular width) it's a persistent leading column. A city-selector Setup is
/// presented on first launch / from the sidebar. Kicks off the initial loads
/// (cache-first, then network).
struct RootView: View {
    @Environment(ShowsStore.self) private var store
    @Environment(ClassesStore.self) private var classesStore
    @Environment(GoingStore.self) private var going
    @Environment(TalentStore.self) private var talent
    @Environment(AppState.self) private var app
    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some View {
        @Bindable var app = app
        Group {
            if hSize == .regular {
                // iPad: persistent theater column, no drawer.
                HStack(spacing: 0) {
                    TheaterListPanel()
                        .frame(width: 320)
                        .background(.regularMaterial)
                    Divider().ignoresSafeArea()
                    tabs
                }
            } else {
                ZStack {
                    tabs
                    TheaterSidebar()
                }
            }
        }
        .task { await store.loadInitial() }
        .task { await classesStore.loadInitial() }
        .task { await talent.loadInitial() }
        .task { updateVenues() }
        .onChange(of: store.lastUpdated) { _, _ in updateVenues() }
        .modifier(UITestTabSelection(selection: $app.activeTab))
        .modifier(UITestSidebar())
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedSetup },
            set: { if !$0 { hasCompletedSetup = true } }
        )) {
            SetupFlowView(app: app) { hasCompletedSetup = true }
        }
        .sheet(isPresented: $app.showCityPicker) {
            SetupView(app: app, isOnboarding: false) { app.showCityPicker = false }
        }
    }

    private var tabs: some View {
        @Bindable var app = app
        return TabView(selection: $app.activeTab) {
            ShowsFeedView()
                .tabItem { Label("Shows", systemImage: "theatermasks") }
                .tag(0)

            TicketWalletView()
                .tabItem { Label("Tickets", systemImage: "ticket") }
                .badge(tickets.reserved.count + going.count)
                .tag(1)

            ClassesView()
                .tabItem { Label("Classes", systemImage: "graduationcap") }
                .tag(2)
        }
    }

    /// Which UCB venues have a show today (in the venue's own timezone) — gates
    /// the standby geofence so it only arms when at-the-door entry is possible.
    private func updateVenues() {
        var out: Set<String> = []
        for venue in Venue.all {
            let tz = (venue.id == "ucb_la" ? City.losAngeles : City.newYork).timeZone
            let cal = DateUtils.calendar(in: tz)
            let now = Date()
            let hasShow = store.allShows.contains { show in
                show.source == venue.id
                    && (show.startDate.map { cal.isDate($0, inSameDayAs: now) } ?? false)
            }
            if hasShow { out.insert(venue.id) }
        }
        tickets.venuesWithShowsToday = out
        if account.isSignedIn { Task { await tickets.rearmGeofences() } }
    }
}
