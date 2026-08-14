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
                .task(id: account.isSignedIn) {
                    if account.isSignedIn { await tickets.sync() }
                    openDeepLink(app.openTicketID)
                }
                .onChange(of: app.openTicketID) { _, id in openDeepLink(id) }
                // Retry the deep link once the target ticket lands in the store.
                .onChange(of: tickets.reserved) { _, _ in openDeepLink(app.openTicketID) }
                .onChange(of: tickets.studentID) { _, _ in openDeepLink(app.openTicketID) }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.section,
                       pinnedViews: [.sectionHeaders]) {
                Group {
                    if account.isSignedIn {
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
        if let sid = tickets.studentID {
            section("Student ID") {
                NavigationLink(value: sid) { StudentIDCard(ticket: sid, freeRemaining: account.freeRemaining) }
                    .buttonStyle(.plain)
            }
        }

        section("Reserved shows") {
            if tickets.reserved.isEmpty {
                Text("No reserved shows yet. Reserve a free student ticket from any participating UCB show.")
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
            ShowSectionsList(sections: DaySection.group(going.shows), namespace: zoom)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    private func openDeepLink(_ id: String?) {
        guard let id, account.isSignedIn, let ticket = tickets.ticket(id: id) else { return }
        if path.isEmpty { path.append(ticket) }
        app.openTicketID = nil
    }
}

// MARK: - Cards

private struct StudentIDCard: View {
    let ticket: Ticket
    let freeRemaining: Int

    var body: some View {
        HStack(spacing: 16) {
            QRCodeView(svg: ticket.qrSVG)
                .frame(width: 84, height: 84)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("UCB Student ID").font(.headline)
                if let name = ticket.name, !name.isEmpty {
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(freeRemaining) free show\(freeRemaining == 1 ? "" : "s") left this week")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
