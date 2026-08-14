import SwiftUI

/// The student-ticket CTA on a UCB show. Renders only when it's useful: a
/// prompt to sign in, a one-tap "Reserve free student ticket" when eligible and
/// the show has student seats, or a "reserved" confirmation. Anything else
/// (not enrolled, sold out, excluded show) renders nothing so the normal
/// Get-Tickets button stands alone.
struct StudentReserveButton: View {
    let show: Show
    let onSignIn: () -> Void

    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(AppState.self) private var app

    private enum Phase: Equatable { case hidden, signInPrompt, checking, available, reserving, reserved, failed(String) }
    @State private var phase: Phase = .hidden

    private var isUCB: Bool { show.source == "ucb_ny" || show.source == "ucb_la" }
    /// Exclude only shows with no in-person seat: most UCB shows are hybrid
    /// (Mainstage + a livestream option) and DO have student tickets — the feed
    /// flags those `isLivestream` too, so keying off the flag alone hid the
    /// reserve button on nearly every show. Pure livestreams have no physical
    /// venue ("Livestream" is the venue).
    private var excluded: Bool {
        (show.isLivestream && show.venue.caseInsensitiveCompare("Livestream") == .orderedSame)
            || show.title.localizedCaseInsensitiveContains("asssscat")
    }

    var body: some View {
        // Static gates decide membership in the layout; the async probe only
        // runs for shows that could ever have a student CTA.
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
            // A zero-size color keeps the view (and its task) alive.
            Color.clear.frame(width: 0, height: 0)
        case .signInPrompt:
            Button(action: onSignIn) {
                Label("Students: sign in for a free ticket", systemImage: "graduationcap")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .available:
            Button {
                Task { await reserve() }
            } label: {
                Label("Reserve free student ticket", systemImage: "graduationcap.fill")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
        case .reserving:
            ProgressView().frame(maxWidth: .infinity).controlSize(.large)
        case .reserved:
            Button {
                app.openTicketID = nil
                app.activeTab = 1
            } label: {
                Label("Student ticket reserved — view", systemImage: "checkmark.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.green)
        case .failed(let msg):
            Text(msg).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var taskKey: String { "\(show.id)|\(account.phase)" }

    private func evaluate() async {
        guard isUCB, !excluded, let url = show.url else { phase = .hidden; return }
        guard account.isSignedIn else { phase = .signInPrompt; return }
        if case .reserved = phase { return }
        phase = .checking
        // The show page is the source of truth: a claim control appears only
        // when THIS account can claim THIS show — no need to pre-gate on the
        // separately-parsed eligibility flag (which can false-negative). The
        // session caches this per show, so re-opening doesn't re-navigate.
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
