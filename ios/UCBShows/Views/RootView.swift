import SwiftUI

/// Two-tab shell: Shows and Classes — with a left theater sidebar overlaying the
/// whole TabView (opened from each tab's hamburger button) and a city-selector
/// Setup presented on first launch / from the sidebar. Kicks off the initial
/// loads (cache-first, then network).
struct RootView: View {
    @Environment(ShowsStore.self) private var store
    @Environment(ClassesStore.self) private var classesStore
    @Environment(AppState.self) private var app
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false
    @State private var selection = 0

    var body: some View {
        @Bindable var app = app
        ZStack {
            TabView(selection: $selection) {
                ShowsFeedView()
                    .tabItem { Label("Shows", systemImage: "theatermasks") }
                    .tag(0)

                ClassesView()
                    .tabItem { Label("Classes", systemImage: "graduationcap") }
                    .tag(1)
            }

            TheaterSidebar()
        }
        .task { await store.loadInitial() }
        .task { await classesStore.loadInitial() }
        .modifier(UITestTabSelection(selection: $selection))
        .modifier(UITestSidebar())
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedSetup },
            set: { if !$0 { hasCompletedSetup = true } }
        )) {
            SetupView(app: app, isOnboarding: true) { hasCompletedSetup = true }
        }
        .sheet(isPresented: $app.showCityPicker) {
            SetupView(app: app, isOnboarding: false) { app.showCityPicker = false }
        }
    }
}
