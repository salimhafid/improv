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
    @Environment(GoingStore.self) private var going
    @Environment(TalentStore.self) private var talent
    @Environment(AppState.self) private var app
    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(\.horizontalSizeClass) private var hSize

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
        .modifier(UITestTabSelection(selection: $app.activeTab))
        .modifier(UITestSidebar())
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

}
