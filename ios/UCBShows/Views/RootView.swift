import SwiftUI

/// Three-tab shell: Shows, I'm Going, and Classes — scoped (except I'm Going) to
/// the theater chosen in the left sidebar. On iPhone the sidebar is a drawer
/// overlaying the TabView (opened from each tab's hamburger button); on iPad
/// (regular width) it's a persistent leading column. A city-selector Setup is
/// presented on first launch / from the sidebar. Kicks off the initial loads
/// (cache-first, then network).
struct RootView: View {
    @Environment(ShowsStore.self) private var store
    @Environment(ClassesStore.self) private var classesStore
    @Environment(GoingStore.self) private var going
    @Environment(AppState.self) private var app
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
        .modifier(UITestTabSelection(selection: $app.activeTab))
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

    private var tabs: some View {
        @Bindable var app = app
        return TabView(selection: $app.activeTab) {
            ShowsFeedView()
                .tabItem { Label("Shows", systemImage: "theatermasks") }
                .tag(0)

            GoingView()
                .tabItem { Label("I’m Going", systemImage: "heart") }
                .badge(going.count)
                .tag(1)

            ClassesView()
                .tabItem { Label("Classes", systemImage: "graduationcap") }
                .tag(2)
        }
    }
}
