import SwiftUI

/// Three-tab shell: Shows, Classes, and Tickets (which also holds the hearted
/// "I'm Going" shows) — Shows and Classes are scoped to
/// the theaters chosen in the left sidebar (all cities, one list). On iPhone
/// the sidebar is a drawer overlaying the TabView (opened from each tab's
/// hamburger button); on iPad (regular width) it's a persistent leading column.
/// There's no onboarding — a fresh install lands on UCB New York and the city
/// follows from whatever the sidebar holds. Kicks off the initial loads
/// (cache-first, then network).
struct RootView: View {
    @Environment(ShowsStore.self) private var store
    @Environment(ClassesStore.self) private var classesStore
    @Environment(TalentStore.self) private var talent
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        @Bindable var app = app
        let regular = hSize == .regular
        // One `tabs` instance with the chrome arranged around it. Putting it in
        // either branch of an `if` made a compact↔regular flip (iPad Split
        // View, Slide Over) recreate the TabView and drop every tab's
        // navigation path, search text and expanded folders.
        HStack(spacing: 0) {
            if regular {
                // iPad: persistent theater column, no drawer.
                TheaterListPanel()
                    .frame(width: 320)
                    .background(.regularMaterial)
                Divider().ignoresSafeArea()
            }
            tabs
                // The open drawer covers the tabs; keep VoiceOver from
                // wandering into the content behind the scrim. (Applied before
                // the overlay so the drawer itself stays reachable.)
                .accessibilityHidden(!regular && app.sidebarOpen)
                .overlay {
                    if !regular { TheaterSidebar() }
                }
        }
        .onChange(of: hSize) { _, size in
            // No drawer at regular width — a drawer left open before the flip
            // must not pop back open on the way back to compact.
            if size == .regular { app.sidebarOpen = false }
        }
        .task { await store.loadInitial() }
        .task { await classesStore.loadInitial() }
        .task { await talent.loadInitial() }
        .modifier(UITestTabSelection(selection: $app.activeTab))
        .modifier(UITestSidebar())
    }

    private var tabs: some View {
        @Bindable var app = app
        return TabView(selection: $app.activeTab) {
            ShowsFeedView()
                .tabItem { Label("Shows", systemImage: "theatermasks") }
                .tag(0)

            // No count badge on this tab: the reminder an hour before showtime
            // is the proactive surface, not a permanent red number.
            TicketWalletView()
                .tabItem { Label("Tickets", systemImage: "ticket") }
                .tag(1)

            ClassesView()
                .tabItem { Label("Classes", systemImage: "graduationcap") }
                .tag(2)
        }
    }

}
