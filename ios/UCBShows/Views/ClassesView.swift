import SwiftUI

/// Classes & workshops for the currently selected theater (chosen in the
/// hamburger sidebar), grouped by level. An inline search bar sits above the
/// list. Tapping a class pushes a native detail page (with Register from there).
struct ClassesView: View {
    @Environment(ClassesStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showFilters = false
    @State private var query = ""

    private var city: String { app.selectedCity.rawValue }
    private var theater: String { app.selectedTheater }
    private var theaterName: String { app.scopeTitle }

    var body: some View {
        NavigationStack {
            Group {
                if store.allClasses.isEmpty {
                    switch store.phase {
                    case .loading: SkeletonList()
                    case .failed(let message): errorState(message)
                    default: emptyDataState
                    }
                } else if store.filtered(city: city, theater: theater, searchText: query).isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(theaterName)
            .toolbar {
                hamburgerToolbarItem
                filterToolbarItem
            }
            .navigationDestination(for: ClassItem.self) { item in
                ClassDetailView(item: item)
            }
            .searchable(text: $query, prompt: "Search \(theaterName) classes")
            .sheet(isPresented: $showFilters) {
                ClassFilterSheet(store: store, city: city, theater: theater)
            }
            .refreshable { await store.refresh() }
            .onSwipeRight {                             // swipe L→R opens the theater drawer
                if hSize == .compact { app.sidebarOpen = true }
            }
            .task { store.reconcileLevel(city: city, theater: theater) }
            .onChange(of: theater) { _, _ in
                // Scope changed — drop a level not offered by the new theater.
                store.reconcileLevel(city: city, theater: theater)
            }
            .onChange(of: store.lastUpdated) { _, _ in
                // Keyed on the timestamp, not the count, so a same-count refresh
                // still reconciles.
                store.reconcileLevel(city: city, theater: theater)
                if ProcessInfo.processInfo.uiTestClassFilter, !store.allClasses.isEmpty {
                    showFilters = true
                }
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.section,
                       pinnedViews: [.sectionHeaders]) {
                if store.phase == .offline {
                    OfflineBanner(updatedLabel: store.updatedLabel)
                }

                ForEach(store.sections(city: city, theater: theater, searchText: query)) { section in
                    Section {
                        ForEach(Array(section.classes.enumerated()), id: \.element.id) { index, item in
                            VStack(spacing: 0) {
                                rowButton(item)
                                if index < section.classes.count - 1 {
                                    Divider().padding(.leading, 64)
                                }
                            }
                            .padding(.horizontal, Theme.Space.gutter)
                        }
                    } header: {
                        SectionHeaderView(title: section.title)
                    }
                }

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

    private func rowButton(_ item: ClassItem) -> some View {
        NavigationLink(value: item) { ClassRow(item: item) }
            .buttonStyle(.plain)
    }

    // MARK: States

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if store.filters.isActive {
            noMatchesState
        } else {
            noClassesForTheater
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label("No Classes Match", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Try removing a filter to see more classes.")
        } actions: {
            Button("Clear Filters") { store.filters.clear() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var noClassesForTheater: some View {
        ContentUnavailableView {
            Label("No Classes", systemImage: "graduationcap")
        } description: {
            Text("\(theaterName) has no classes listed. Try another theater.")
        } actions: {
            Button("Choose Theater") { app.sidebarOpen = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var emptyDataState: some View {
        ContentUnavailableView(
            "No Classes Yet",
            systemImage: "graduationcap",
            description: Text("Check back soon for upcoming classes.")
        )
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can’t Load Classes", systemImage: "wifi.exclamationmark")
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
}

/// Skeleton placeholder shown on first load of the Classes tab.
private struct SkeletonList: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 160, height: 12)
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
