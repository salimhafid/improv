import SwiftUI

/// The student-ticket control on a UCB show — a compact icon button that sits
/// between the "I'm Going" heart and Get Tickets. Renders only when it's
/// useful: a prompt to sign in, one-tap reserve when eligible and the show has
/// student seats, or a reserved confirmation. Anything else (not enrolled,
/// sold out, excluded show) collapses to nothing so the bar reads as two
/// buttons.
struct StudentReserveButton: View {
    /// Must match the bottom bar's HStack spacing — the hidden state cancels
    /// its own layout slot with this, so an absent CTA doesn't double the gap
    /// between the heart and Get Tickets.
    static let barSpacing: CGFloat = 12

    let show: Show
    let onSignIn: () -> Void

    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(AppState.self) private var app

    private enum Phase: Equatable { case hidden, signInPrompt, checking, available, reserving, reserved, failed(String) }
    @State private var phase: Phase = .hidden
    @State private var failureMessage: String?

    private var isUCB: Bool { show.source == "ucb_ny" || show.source == "ucb_la" }
    private var excluded: Bool {
        (show.isLivestream && show.venue.caseInsensitiveCompare("Livestream") == .orderedSame)
            || show.title.localizedCaseInsensitiveContains("asssscat")
    }

    var body: some View {
        if isUCB, !excluded, show.url != nil {
            content
                .task(id: taskKey) { await evaluate() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden, .checking:
            // NOT EmptyView: SwiftUI never fires .task/.onAppear on EmptyView,
            // which left evaluate() unrun and the button permanently hidden.
            // A zero-size color keeps the view (and its task) alive; the
            // negative padding cancels the HStack slot it would otherwise hold.
            Color.clear
                .frame(width: 0, height: 0)
                .padding(.leading, -Self.barSpacing)
        case .signInPrompt:
            Button(action: onSignIn) {
                Image(systemName: "graduationcap")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Sign in for a free student ticket")
        case .available:
            Button {
                Task { await reserve() }
            } label: {
                Image(systemName: "graduationcap.fill")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.accent)
            .accessibilityLabel("Reserve free student ticket")
        case .reserving:
            ProgressView()
                .controlSize(.regular)
                .frame(width: 44, height: 44)
        case .reserved:
            Button {
                app.openTicketID = nil
                app.activeTab = 1
            } label: {
                Image(systemName: "graduationcap.fill")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.green)
            .accessibilityLabel("Student ticket reserved — view")
        case .failed(let message):
            // Icon-only leaves no room for the reason, so it moves into an
            // alert; the button itself retries rather than bouncing an
            // already-signed-in user to the sign-in sheet.
            Button {
                failureMessage = message
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
            .accessibilityLabel("Student ticket failed — tap for details")
            .alert("Couldn’t Reserve", isPresented: showingFailure) {
                Button("Try Again") { Task { await reserve() } }
                Button("OK", role: .cancel) {}
            } message: {
                Text(message)
            }
        }
    }

    /// Bound to the alert so dismissing it clears the stored reason.
    private var showingFailure: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
    }

    private var taskKey: String { "\(show.id)|\(account.phase)" }

    private func evaluate() async {
        guard isUCB, !excluded, let url = show.url else { phase = .hidden; return }
        // Mid-restore we don't know yet, and "sign in for a free student
        // ticket" is the wrong thing to tell someone who already is. `taskKey`
        // interpolates `account.phase`, so this re-runs the moment it resolves.
        guard !account.isRestoring else { phase = .hidden; return }
        guard account.isSignedIn else { phase = .signInPrompt; return }
        if case .reserved = phase { return }
        phase = .checking
        let a = await account.session.claimAvailability(showURL: url)
        if Task.isCancelled { return }
        phase = a.alreadyClaimed ? .reserved : (a.available ? .available : .hidden)
    }

    private func reserve() async {
        phase = .reserving
        let result = await tickets.reserve(show: show)
        phase = result.success ? .reserved : .failed(result.message)
    }
}
