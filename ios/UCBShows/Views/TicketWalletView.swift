import SwiftUI

/// The Tickets tab — everything the user is holding for a night out: the
/// standby UCB Student ID and reserved student tickets up top (each opening a
/// full-screen QR), and the shows they've hearted ("I'm Going") below, grouped
/// by date. Signed out, the ticket half collapses to a connect card; the
/// hearted list is always available.
struct TicketWalletView: View {
    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(GoingStore.self) private var going
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// NavigationPath (not a typed array) — this stack pushes heterogeneous
    /// values: Tickets, Shows, and TalentRoutes from a pushed show's cast chips.
    @State private var path = NavigationPath()
    @State private var showSignIn = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Tickets")
                .navigationDestination(for: Ticket.self) { ticket in
                    TicketDetailView(ticket: ticket) { t in await tickets.release(t) }
                }
                .navigationDestination(for: Show.self) { show in
                    ShowDetailView(show: show, namespace: zoom)
                }
                .sheet(isPresented: $showSignIn) { UCBSignInView(account: account) }
                // Re-runs when sign-in state flips, so a first-ever sign-in pulls
                // the Student ID + tickets without needing a pull-to-refresh.
                // Throttled: revisiting the tab within a few minutes is instant.
                .task(id: account.isSignedIn) {
                    if account.isSignedIn { await tickets.syncIfStale() }
                    // That sync is an uninterruptible web-view navigation, so
                    // we can resume here half a minute later on a screen the
                    // user has long since left.
                    if Task.isCancelled { return }
                    openDeepLink(app.openTicketID)
                    await askForRemindersIfVisible()
                }
                .onChange(of: app.openTicketID) { _, id in openDeepLink(id) }
                // Retry the deep link once the target ticket lands in the store.
                .onChange(of: tickets.reserved) { _, _ in openDeepLink(app.openTicketID) }
                .onChange(of: tickets.studentID) { _, _ in openDeepLink(app.openTicketID) }
                // A TabView keeps unselected children alive, so `.task` above
                // doesn't re-run when the user finally lands here — this is
                // what makes arriving on the tab the notifiable moment.
                .onChange(of: app.activeTab) { _, _ in
                    Task { await askForRemindersIfVisible() }
                }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.section,
                       pinnedViews: [.sectionHeaders]) {
                Group {
                    // Optimistic, not confirmed: the wallet is decoded from
                    // disk before the first frame, while confirming the session
                    // is a 1–20s web-view round trip. Gating on `isSignedIn`
                    // put the connect card in front of a Student ID that was
                    // already in memory. Deliberately NOT gated on cached
                    // content — a genuinely signed-out user can keep a stale
                    // tickets.json indefinitely (see `TicketStore.adopt`), and
                    // that must still show the connect card.
                    if account.hasSession {
                        ticketSections
                    } else {
                        connectCard
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)

                goingSection

                if account.isSignedIn {
                    Button("Sign out of UCB", role: .destructive) {
                        Task {
                            await account.signOut()
                            tickets.clearLocal()   // disarm geofences + cancel reminders
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, 8)
                }
            }
            .padding(.top, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.section)
        }
        .refreshable {
            if account.isSignedIn { await tickets.sync() }
        }
    }

    // MARK: Tickets (signed in)

    @ViewBuilder
    private var ticketSections: some View {
        if account.isRestoring, !tickets.hasAnything {
            // A marker but nothing cached: a genuine unknown, so say so. A
            // determinate placeholder — never the connect card, and never a
            // spinner in front of a QR someone is trying to get scanned.
            checkingCard
        } else {
            if let sid = tickets.studentID {
                section("Student ID", busy: account.isRestoring) {
                    NavigationLink(value: sid) { StudentIDCard(ticket: sid, freeRemaining: account.freeRemaining,
                                                  isRestoring: account.isRestoring) }
                        .buttonStyle(.plain)
                }
            }

            // The chip belongs to whichever section leads, so it shows once.
            section("Reserved shows", busy: account.isRestoring && tickets.studentID == nil) {
                if tickets.reserved.isEmpty {
                    // Mid-check we haven't read the wallet yet, so "none" would
                    // be a claim the app can't support.
                    Text(account.isRestoring
                         ? "Checking your UCB account…"
                         : "No reserved shows yet. Reserve a free student ticket from any participating UCB show.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(tickets.reserved) { ticket in
                            NavigationLink(value: ticket) { ReservedRow(ticket: ticket) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Connect (signed out)

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect your UCB account", systemImage: "ticket")
                .font(.headline)
            Text("Sign in to reserve free student tickets, carry them as a QR, and get a nudge when you reach the theater.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Sign in to UCB") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Restoring (marker present, nothing cached)

    /// Deliberately the same chrome as `connectCard` so the swap to real
    /// content isn't a layout jump.
    private var checkingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            VStack(alignment: .leading, spacing: 2) {
                Text("Checking your UCB account…").font(.headline)
                Text("Your Student ID and reserved tickets will appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: I'm Going (hearted shows)

    @ViewBuilder
    private var goingSection: some View {
        Text("I’m Going")
            .font(.title3.weight(.bold))
            .padding(.horizontal, Theme.Space.gutter)

        if going.shows.isEmpty {
            Text("Tap the heart on a show’s page and it’ll show up here, with a reminder before showtime.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.gutter)
        } else {
            // Tag by the list's own contents — hearted shows can span cities
            // regardless of the current sidebar selection.
            ShowSectionsList(sections: DaySection.group(going.shows), namespace: zoom,
                             showsCityTags: Set(going.shows.map(\.city)).count > 1)
        }
    }

    // MARK: Helpers

    /// `busy` adds a small inline chip to the header — the whole "we're still
    /// checking" affordance. Never a spinner over the QR itself: a stale-by-
    /// four-seconds code still scans at the box office; a spinner doesn't.
    @ViewBuilder
    private func section<Content: View>(_ title: String, busy: Bool = false,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.title3.weight(.bold))
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            // Otherwise VoiceOver re-announces the header when the chip drops.
            .accessibilityElement(children: .combine)
            content()
        }
        .animation(.default, value: busy)
    }

    private func openDeepLink(_ id: String?) {
        guard let id else { return }
        // Resolve BEFORE gating on the session. Reminders are armed from the
        // decoded wallet, including one adopted from iCloud on a device that
        // never signed in here — so a wallet good enough to notify from is good
        // enough to open. Anything else would fire a banner that does nothing.
        guard let ticket = tickets.ticket(id: id) else {
            // Unresolvable and no session to ever resolve it: drop the id so it
            // can't fire on some later, unrelated sign-in.
            if !account.hasSession { app.openTicketID = nil }
            return
        }
        if path.isEmpty { path.append(ticket) }
        app.openTicketID = nil
    }

    /// Ask for notification permission only while the wallet is genuinely on
    /// screen. The `.task` above can resume half a minute after an
    /// uninterruptible session read, and a `TabView` keeps unselected children
    /// alive — without these guards the system alert surfaced on whatever
    /// screen the user had moved on to. `ensureReminderAuthorization` is silent
    /// unless there's really something to be reminded about.
    private func askForRemindersIfVisible() async {
        guard scenePhase == .active, app.activeTab == 1 else { return }
        await tickets.ensureReminderAuthorization()
    }
}

// MARK: - Cards

/// Wallet-pass style: the QR takes the full card width so it can be scanned
/// straight from the Tickets tab; tapping still opens the max-brightness view.
private struct StudentIDCard: View {
    let ticket: Ticket
    let freeRemaining: Int
    var isRestoring = false

    var body: some View {
        VStack(spacing: 12) {
            QRCodeView(svg: ticket.qrSVG)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UCB Student ID").font(.headline)
                    if let name = ticket.name, !name.isEmpty {
                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    // `freeRemaining` isn't cached, so it reads 0 until the
                    // account lands — and "0 free shows left" is a worse lie
                    // than saying nothing while we check.
                    if !isRestoring {
                        Text("\(freeRemaining) free show\(freeRemaining == 1 ? "" : "s") left this week")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReservedRow: View {
    let ticket: Ticket

    var body: some View {
        HStack(spacing: 14) {
            QRCodeView(svg: ticket.qrSVG)
                .frame(width: 56, height: 56)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(ticket.title).font(.headline).lineLimit(2)
                Text([ticket.whenLabel, Ticket.cleanVenue(ticket.venueLabel)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
