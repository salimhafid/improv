import SwiftUI

/// Tab 1 — the date-sectioned chronological feed for the currently selected
/// theater (chosen in the hamburger sidebar). An inline search bar sits above the
/// list (revealed by scrolling to the top).
struct ShowsFeedView: View {
    @Environment(ShowsStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(TalentStore.self) private var talent
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showFilters = false
    @State private var query = ""
    @State private var path = NavigationPath()
    @Namespace private var zoom

    private var city: String { app.selectedCity.rawValue }
    private var theater: String { app.selectedTheater }
    private var theaterName: String { app.scopeTitle }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.allShows.isEmpty {
                    switch store.phase {
                    case .loading: SkeletonFeed()
                    case .failed(let message): errorState(message)
                    default: emptyDataState
                    }
                } else if store.filtered(city: city, theater: theater, searchText: query).isEmpty {
                    emptyState
                } else {
                    feed
                }
            }
            .navigationTitle(theaterName)
            .toolbar {
                hamburgerToolbarItem
                filterToolbarItem
            }
            .navigationDestination(for: Show.self) { show in
                ShowDetailView(show: show, namespace: zoom)
            }
            .searchable(text: $query, prompt: "Search \(theaterName)")
            .sheet(isPresented: $showFilters) {
                FilterSheet(store: store, city: city, theater: theater)
            }
            .refreshable { await store.refresh() }
            .onSwipeRight {                             // swipe L→R opens the theater drawer
                if hSize == .compact { app.sidebarOpen = true }
            }
            .task { store.reconcileFilters(city: city, theater: theater) }
            .onChange(of: theater) { _, _ in
                // Scope changed — drop venue/types not in the new theater.
                store.reconcileFilters(city: city, theater: theater)
            }
            .onChange(of: store.lastUpdated) { _, _ in
                // Re-reconcile on every successful load (keyed on the timestamp,
                // not the count, so a same-count refresh still reconciles).
                maybeAutoPush()
                store.reconcileFilters(city: city, theater: theater)
            }
            .onChange(of: talent.loaded) { _, _ in
                maybeAutoPushTalent()
            }
        }
    }

    // MARK: Feed

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.section, pinnedViews: [.sectionHeaders]) {
                if store.phase == .offline {
                    OfflineBanner(updatedLabel: store.updatedLabel)
                }

                ShowSectionsList(
                    sections: store.sections(city: city, theater: theater, searchText: query),
                    namespace: zoom
                )

                if let updated = store.updatedLabel, store.phase != .offline {
                    Text(updated)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(.top, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.section)
        }
    }

    // MARK: States

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if store.filters.isActive {
            noMatchesState
        } else {
            noShowsForTheater
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label("No Shows Match", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Try removing a filter to see more shows.")
        } actions: {
            Button("Clear Filters") { store.filters.clear() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var noShowsForTheater: some View {
        ContentUnavailableView {
            Label("No Upcoming Shows", systemImage: "theatermasks")
        } description: {
            Text("\(theaterName) has no upcoming shows right now. Try another theater.")
        } actions: {
            Button("Choose Theater") { app.sidebarOpen = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var emptyDataState: some View {
        ContentUnavailableView(
            "No Upcoming Shows",
            systemImage: "theatermasks",
            description: Text("Check back soon for new shows.")
        )
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can’t Load Shows", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await store.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The drawer only exists on compact width — iPad shows a persistent column.
    @ToolbarContentBuilder
    private var hamburgerToolbarItem: some ToolbarContent {
        if hSize == .compact {
            ToolbarItem(placement: .topBarLeading) {
                Button { app.sidebarOpen = true } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Theaters")
            }
        }
    }

    private var filterToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showFilters = true
            } label: {
                FilterToolbarIcon(activeCount: store.filters.activeCount)
            }
        }
    }

    /// DEBUG-only: push a show from a requested source (verification screenshots).
    private func maybeAutoPush() {
        guard path.isEmpty, let src = ProcessInfo.processInfo.uiTestPushSource else { return }
        let pick = store.allShows.first { $0.source == src && $0.hasCast }
            ?? store.allShows.first { $0.source == src }
        if let pick {
            path.append(pick)
            maybeAutoPushTalent()
        }
    }

    /// DEBUG-only: push the talent directory or a performer bio on top of the
    /// auto-pushed show (verification screenshots).
    private func maybeAutoPushTalent() {
        guard path.count == 1, talent.loaded,
              let what = ProcessInfo.processInfo.uiTestTalent else { return }
        switch what {
        case "directory":
            path.append(TalentRoute.directory(initialSearch: ""))
        case "person":
            if let person = talent.allPeople.first {
                path.append(TalentRoute.person(person))
            }
        default:
            if let person = talent.person(named: what) {
                path.append(TalentRoute.person(person))
            }
        }
    }
}

/// Skeleton placeholder shown on first load instead of a bare spinner.
private struct SkeletonFeed: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 230)
                    .padding(.horizontal, Theme.Space.gutter)
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 92, height: 58)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 140, height: 12)
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                }
            }
            .padding(.top, Theme.Space.gutter)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}
