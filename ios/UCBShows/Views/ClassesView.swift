import SwiftUI

/// Classes & workshops organized by school folder. Classes are browsed
/// city-wide: every school in the selected theaters' cities gets a card with
/// collapsible subject sub-sections inside, the picked theaters first. The city
/// is inferred from the sidebar selection — it's never asked for.
struct ClassesView: View {
    @Environment(ClassesStore.self) private var store
    @Environment(ClassAlertsStore.self) private var alertsStore
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showAlerts = false
    @State private var query = ""
    @State private var expandedSchool: String?
    @State private var expandedSubjects: Set<String> = []

    private var theaters: Set<String> { app.selectedTheaters }
    private var title: String { app.scopeCityName ?? "Classes" }
    private var searchPrompt: String {
        app.scopeCityName.map { "Search \($0) classes" } ?? "Search classes"
    }

    var body: some View {
        let layout = store.schoolFolders(theaters: theaters, searchText: query)
        NavigationStack {
            Group {
                if store.allClasses.isEmpty {
                    switch store.phase {
                    case .loading: SkeletonList()
                    case .failed(let message): errorState(message)
                    default: emptyDataState
                    }
                } else if layout.selected.isEmpty {
                    emptyState
                } else {
                    list(layout)
                }
            }
            .navigationTitle(title)
            .toolbar {
                hamburgerToolbarItem
                alertsToolbarItem
            }
            .navigationDestination(for: ClassItem.self) { item in
                ClassDetailView(item: item)
            }
            .searchable(text: $query, prompt: searchPrompt)
            .sheet(isPresented: $showAlerts) {
                ClassAlertsView()
            }
            .refreshable { await store.refresh() }
            .onSwipeRight {
                if hSize == .compact { app.sidebarOpen = true }
            }
            .onChange(of: theaters) { _, _ in
                // A new sidebar pick is a new city's worth of schools, so start
                // it fully collapsed rather than leaving a card from the old
                // scope open.
                expandedSchool = nil
                expandedSubjects = []
            }
        }
    }

    // MARK: List

    private func list(_ layout: SchoolFolderLayout) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.phase == .offline {
                    OfflineBanner(updatedLabel: store.updatedLabel)
                        .padding(.bottom, 8)
                }

                ForEach(layout.selected) { folder in
                    schoolCard(folder)
                }

                if let updated = store.updatedLabel, store.phase != .offline {
                    Text(updated)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.section)
        }
    }

    // MARK: School Card

    private func schoolCard(_ folder: SchoolFolder) -> some View {
        let isOpen = expandedSchool == folder.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    expandedSchool = isOpen ? nil : folder.id
                }
            } label: {
                HStack(spacing: 12) {
                    TheaterIcon(id: folder.id, size: 36)
                    Text(folder.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text("\(folder.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isOpen)

            if isOpen {
                ForEach(folder.subjects) { group in
                    subjectSection(group)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 10)
    }

    // MARK: Subject Sub-section

    private func subjectSection(_ group: SubjectGroup) -> some View {
        let isOpen = expandedSubjects.contains(group.id)
        return VStack(spacing: 0) {
            Divider().padding(.leading, 14)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOpen {
                        expandedSubjects.remove(group.id)
                    } else {
                        expandedSubjects.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("\(group.classes.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                ForEach(Array(group.classes.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        if index > 0 {
                            Divider().padding(.leading, 72)
                        }
                        NavigationLink(value: item) {
                            ClassRow(item: item, showsCityTag: app.spansMultipleCities)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                    }
                }
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            noClassesForCity
        }
    }

    private var noClassesForCity: some View {
        ContentUnavailableView {
            Label("No Classes", systemImage: "graduationcap")
        } description: {
            // The list is city-wide, so an empty one is the city's fault, not
            // the picked theater's.
            Text(app.scopeCityName.map { "No classes listed in \($0) right now." }
                ?? "No classes listed in the selected cities right now.")
        } actions: {
            if hSize == .compact {
                Button("Choose Theater") { app.sidebarOpen = true }
                    .buttonStyle(.borderedProminent)
            }
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
            Label("Can't Load Classes", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await store.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

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

    private var alertsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAlerts = true
            } label: {
                Image(systemName: alertsStore.activeCount > 0 ? "bell.badge.fill" : "bell")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Class alerts")
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
