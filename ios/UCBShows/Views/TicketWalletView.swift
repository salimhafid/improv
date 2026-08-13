import SwiftUI

/// The Tickets tab — a wallet: the standby UCB Student ID and every reserved
/// student ticket, each opening a full-screen QR. Signed out, it invites the
/// user to connect their UCB account.
struct TicketWalletView: View {
    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(AppState.self) private var app

    @State private var path: [Ticket] = []
    @State private var showSignIn = false
    @State private var refreshing = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !account.isSignedIn {
                    signedOut
                } else {
                    wallet
                }
            }
            .navigationTitle("Tickets")
            .navigationDestination(for: Ticket.self) { ticket in
                TicketDetailView(ticket: ticket) { t in _ = await tickets.release(t) }
            }
            .sheet(isPresented: $showSignIn) { UCBSignInView(account: account) }
            .task { if account.isSignedIn { await tickets.sync() } }
            .onChange(of: app.openTicketID) { _, id in openDeepLink(id) }
            .onAppear { openDeepLink(app.openTicketID) }
        }
    }

    // MARK: Signed in

    private var wallet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
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

                Button("Sign out of UCB", role: .destructive) {
                    Task { await tickets.sync(); await account.signOut() }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(Theme.Space.gutter)
        }
        .refreshable { await tickets.sync() }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        ContentUnavailableView {
            Label("Connect your UCB account", systemImage: "ticket")
        } description: {
            Text("Sign in to reserve free student tickets, carry them as a QR, and get a nudge when you reach the theater.")
        } actions: {
            Button("Sign in to UCB") { showSignIn = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func openDeepLink(_ id: String?) {
        guard let id, account.isSignedIn, let ticket = tickets.ticket(id: id) else { return }
        if path.last != ticket { path.append(ticket) }
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
