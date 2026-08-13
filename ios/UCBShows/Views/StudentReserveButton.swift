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
    private var excluded: Bool {
        show.isLivestream || show.title.localizedCaseInsensitiveContains("asssscat")
    }

    var body: some View {
        content
            .task(id: taskKey) { await evaluate() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden, .checking:
            EmptyView()
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
                app.activeTab = 3
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
        guard isUCB, !excluded, show.url != nil else { phase = .hidden; return }
        guard account.isSignedIn else { phase = .signInPrompt; return }
        if case .reserved = phase { return }
        phase = .checking
        guard let url = show.url else { phase = .hidden; return }
        // The show page is the source of truth: a claim control appears only
        // when THIS account can claim THIS show — no need to pre-gate on the
        // separately-parsed eligibility flag (which can false-negative).
        let a = await account.session.claimAvailability(showURL: url)
        phase = a.alreadyClaimed ? .reserved : (a.available ? .available : .hidden)
    }

    private func reserve() async {
        phase = .reserving
        let result = await tickets.reserve(show: show)
        phase = result.success ? .reserved : .failed(result.message)
    }
}
