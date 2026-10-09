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
    @State private var retrying = false
    /// Held so a class-alert tap can open its class from wherever the stack
    /// was. Untyped: a class page pushes an instructor's bio, and a bio pushes
    /// their shows.
    @State private var path = NavigationPath()
    /// Zoom-transition namespace that `ShowDetailView` requires; shows pushed
    /// from a bio here have no zoom source, so it is never matched.
    @Namespace private var zoom
    /// A tapped alert whose class isn't in the feed yet, and when to stop
    /// looking for it; drives the "just posted" banner. View state rather
    /// than part of the target so a tab switch — which cancels the lookup and
    /// restarts it on return — resumes the same budget instead of a new one.
    @State private var pendingAlert: PendingAlert?

    private struct PendingAlert: Equatable {
        let target: ClassAlertTarget
        let deadline: Date
    }

    /// The watcher alerts within minutes of a class going up; the feed it
    /// lands in is republished a few minutes after that, and the raw CDN can
    /// keep serving the old copy for its 5-minute max-age (query-string cache
    /// busters are ignored). Polling is the only way to see it arrive.
    private static let pendingPollInterval: Duration = .seconds(30)
    private static let pendingBudget: TimeInterval = 10 * 60
    /// How old an alert can be and still have its class "on the way". Past
    /// this, a class missing from the feed has most likely started and left
    /// it (see `ClassAlertTarget.isRecent`), so there is nothing to wait for.
    private static let pendingRecency: TimeInterval = 30 * 60

    private var theaters: Set<String> { app.selectedTheaters }
    /// During a search every folder and subject is held open: the layout only
    /// keeps folders with hits, and hits two collapsed levels deep are as good
    /// as hidden. The user's own expand state is left alone for when the
    /// query clears.
    private var searching: Bool { !query.isEmpty }
    private var title: String { app.scopeCityName ?? "Classes" }
    private var searchPrompt: String {
        app.scopeCityName.map { "Search \($0) classes" } ?? "Search classes"
    }

    var body: some View {
        let layout = store.schoolFolders(theaters: theaters, searchText: query)
        NavigationStack(path: $path) {
            Group {
                if store.allClasses.isEmpty {
                    switch store.phase {
                    case .loading: SkeletonList()
                    case .failed(let message): errorState(message)
                    default: emptyDataState
                    }
                } else {
                    // The empty state is an overlay, not a sibling branch: a
                    // query that momentarily matches nothing used to flip the
                    // `_ConditionalContent` branch, tearing down the ScrollView
                    // and losing the scroll position mid-typing.
                    list(layout)
                        .overlay {
                            if layout.selected.isEmpty {
                                emptyState.background(Color(.systemGroupedBackground))
                            }
                        }
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
            // An instructor's bio (from a class page) and that person's
            // shows (from the bio), as in the Shows tab.
            .navigationDestination(for: TalentRoute.self) { route in
                switch route {
                case .person(let person): TalentBioView(person: person)
                case .directory(let initialSearch): TalentDirectoryView(initialSearch: initialSearch)
                }
            }
            .navigationDestination(for: Show.self) { show in
                ShowDetailView(show: show, namespace: zoom)
            }
            .searchable(text: $query, prompt: searchPrompt)
            .sheet(isPresented: $showAlerts) {
                ClassAlertsView()
            }
            .refreshable { await store.refresh() }
            .onSwipeRight {
                if hSize == .compact { app.sidebarOpen = true }
            }
            .onChange(of: app.scopeCities) { _, _ in
                // A new *city* is a new set of schools, so start it fully
                // collapsed rather than leaving a card from the old scope open.
                // Keyed on the city, not the theater: every theater within one
                // city yields the identical folder set, so clearing on each
                // pick only slammed an open card shut a frame after the list
                // had already re-ordered — and cost a second full body
                // evaluation to do it.
                withAnimation(.snappy(duration: 0.2)) {
                    expandedSchool = nil
                    expandedSubjects = []
                }
            }
        }
        // On the stack, not its root: pushing a class must not cancel a wait
        // for the alerted one. Keyed on the whole target, so a new tap, the
        // record resolving, a dismissal or the tab going away each cancel the
        // run in progress.
        .task(id: app.classAlertTarget) { await followAlert(app.classAlertTarget) }
    }

    // MARK: List

    private func list(_ layout: SchoolFolderLayout) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.phase == .offline {
                    OfflineBanner(updatedLabel: store.updatedLabel, noun: "classes")
                        .padding(.bottom, 8)
                }

                if let pendingAlert {
                    PendingClassBanner(titleHint: pendingAlert.target.titleHint) {
                        dismissPendingAlert()
                    }
                    .transition(.opacity)
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
            // Picking a theater moves it to the front of its city, so the cards
            // re-permute. UCB New York is the default pick and happens to be
            // first already, which is why only the *other* theaters looked
            // broken: identical folders, teleporting in a single frame. Keyed on
            // `orderKey` so expanding a card doesn't drag the whole list into
            // this animation. 0.28s matches the sidebar drawer, so the pick and
            // the re-order read as one motion.
            .animation(.snappy(duration: 0.28), value: layout.orderKey)
        }
    }

    // MARK: School Card

    @ViewBuilder
    private func schoolCard(_ folder: SchoolFolder) -> some View {
        let isOpen = searching || expandedSchool == folder.id
        VStack(spacing: 0) {
            if folder.subjects.isEmpty {
                // A picked theater with nothing in the class feed. Present but
                // inert — there's nothing to open, and a tappable card that
                // does nothing is worse than a labelled empty one.
                cardHeader(folder, isOpen: false, trailing: "No classes listed", chevron: false)
            } else {
                Button {
                    // Held open by the search: a tap has nothing to show and
                    // must not silently change the remembered pick.
                    guard !searching else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        expandedSchool = isOpen ? nil : folder.id
                    }
                } label: {
                    cardHeader(folder, isOpen: isOpen, trailing: "\(folder.count)", chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                // Keyed on the user's own pick, not `isOpen`: a search
                // holding every card open must not fire a haptic per card.
                .sensoryFeedback(.selection, trigger: expandedSchool == folder.id)

                if isOpen {
                    ForEach(folder.subjects) { group in
                        subjectSection(group)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 10)
    }

    private func cardHeader(_ folder: SchoolFolder, isOpen: Bool,
                            trailing: String, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            TheaterIcon(id: folder.id, size: 36)
            Text(folder.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(trailing)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: Subject Sub-section

    private func subjectSection(_ group: SubjectGroup) -> some View {
        let isOpen = searching || expandedSubjects.contains(group.id)
        return VStack(spacing: 0) {
            Divider().padding(.leading, 14)
            Button {
                guard !searching else { return }   // same as the card header above
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
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                // Iterating the array directly, not `Array(enumerated())`: that
                // copied the whole expanded group on every body evaluation
                // purely to decide whether to draw a divider.
                ForEach(group.classes) { item in
                    VStack(spacing: 0) {
                        if item.id != group.classes.first?.id {
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

    // MARK: Class-alert deep link

    /// Open the class a tapped alert names (`AppState.classAlertTarget`),
    /// waiting for it to reach the feed when the alert beat the feed there.
    /// Runs as the `.task` keyed on the target, so it is cancelled and
    /// restarted whenever the target changes, and cancelled when the tab
    /// goes away.
    private func followAlert(_ target: ClassAlertTarget?) async {
        if let pendingAlert, pendingAlert.target.id != target?.id {
            withAnimation(.snappy(duration: 0.25)) { self.pendingAlert = nil }
        }
        guard let target else { return }
        // Record still on its way (bounded at ~10 s): land on the school
        // now; the resolved target re-runs this task.
        if target.isProvisional {
            revealFolder(target.school)
            return
        }
        // A flood summary, or an alert whose record couldn't be read: the
        // school's folder is the closest thing to "that class".
        guard target.classIDs.count == 1 else {
            revealFolder(target.school)
            consume(target)
            return
        }
        // Only this target's wait can still be in `pendingAlert` (see above).
        // One that ran out while the tab was away ends here: pushing a class
        // long after the banner's "few minutes" would be a surprise.
        let deadline = pendingAlert?.deadline ?? Date().addingTimeInterval(Self.pendingBudget)
        guard Date() < deadline else {
            withAnimation(.snappy(duration: 0.25)) { pendingAlert = nil }
            consume(target)
            return
        }
        if let item = store.item(for: target) { open(item, for: target); return }
        // Our copy predates the class; the published feed may not.
        await store.refresh(force: true)
        if Task.isCancelled { return }
        if let item = store.item(for: target) { open(item, for: target); return }

        if pendingAlert == nil {
            // Only a fresh alert's class can still be on its way. An old
            // one's has usually started and dropped off the feed, so promise
            // nothing and land on the school, like an alert naming no class.
            guard target.isRecent(now: Date(), within: Self.pendingRecency) else {
                revealFolder(target.school)
                consume(target)
                return
            }
            withAnimation(.snappy(duration: 0.25)) {
                pendingAlert = PendingAlert(target: target, deadline: deadline)
            }
        }
        while Date() < deadline {
            try? await Task.sleep(for: Self.pendingPollInterval)
            if Task.isCancelled { return }
            await store.refresh(force: true)
            if Task.isCancelled { return }
            if let item = store.item(for: target) { open(item, for: target); return }
        }
        // Still not published: stop promising it.
        withAnimation(.snappy(duration: 0.25)) { pendingAlert = nil }
        consume(target)
    }

    /// Open the alerted class: its folder and subject group expanded behind
    /// it (when the current theater selection shows that school — the
    /// selection is never changed to make it), the stack popped to root and
    /// the class pushed in one assignment, like the Tickets tab's deep links.
    private func open(_ item: ClassItem, for target: ClassAlertTarget) {
        if let folder = openableFolder(item.source) {
            let group = folder.subjects.first { $0.classes.contains { $0.id == item.id } }
            withAnimation(.snappy(duration: 0.25)) {
                expandedSchool = folder.id
                if let group { expandedSubjects.insert(group.id) }
            }
        }
        path = NavigationPath([item])
        if pendingAlert != nil {
            withAnimation(.snappy(duration: 0.25)) { pendingAlert = nil }
        }
        consume(target)
    }

    /// Expand `school`'s folder if the list currently shows one.
    private func revealFolder(_ school: String?) {
        guard let school, let folder = openableFolder(school) else { return }
        withAnimation(.snappy(duration: 0.25)) { expandedSchool = folder.id }
    }

    /// `school`'s folder in the layout on screen, if it has anything to open.
    /// Same key as `body`, so this is a memo hit, not a rebuild.
    private func openableFolder(_ school: String) -> SchoolFolder? {
        store.schoolFolders(theaters: theaters, searchText: query).selected
            .first { $0.id == school && !$0.subjects.isEmpty }
    }

    /// Clear the target — only if it is still this one; a newer tap owns it
    /// otherwise.
    private func consume(_ target: ClassAlertTarget) {
        if app.classAlertTarget?.id == target.id { app.classAlertTarget = nil }
    }

    private func dismissPendingAlert() {
        guard let target = pendingAlert?.target else { return }
        withAnimation(.snappy(duration: 0.25)) { pendingAlert = nil }
        consume(target)
    }

    // MARK: States

    /// Only reachable during a search: with an empty query every picked
    /// theater keeps its folder (see `ClassesStore.buildSchoolFolders`) and
    /// the selection is never empty, so an empty layout always means "no
    /// matches".
    private var emptyState: some View {
        ContentUnavailableView.search(text: query)
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
            // `refresh()` leaves the phase at `.failed` until it resolves, so
            // the button carries its own in-progress state.
            Button {
                retrying = true
                Task {
                    await store.refresh()
                    retrying = false
                }
            } label: {
                if retrying {
                    ProgressView().frame(minWidth: 72)
                } else {
                    Text("Try Again").frame(minWidth: 72)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)
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

/// "Just posted" card at the top of the list while a tapped alert's class is
/// still on its way into the class feed. Styled as a school card so it reads
/// as part of the list rather than an error.
private struct PendingClassBanner: View {
    let titleHint: String?
    let onDismiss: () -> Void

    private static let detail = "It will appear here within a few minutes."

    private var headline: String {
        titleHint.map { "Just posted: \($0)" } ?? "A new class was just posted"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(Self.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Read as one sentence; the dismiss button stays its own stop.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(headline). \(Self.detail)")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 10)
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
