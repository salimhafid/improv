import Foundation
import Observation

/// Auth + identity for the signed-in UCB account. Wraps `UCBSession`; the web
/// view holds the real cookies, so this store only tracks phase, the display
/// name, and student eligibility, plus an on-device Keychain marker so we know
/// to attempt a silent restore on launch.
@MainActor
@Observable
final class UCBAccountStore {
    enum Phase: Equatable { case signedOut, checking, signedIn }

    private(set) var phase: Phase = .signedOut
    private(set) var name = ""
    private(set) var eligible = false
    private(set) var freeRemaining = 0

    let session = UCBSession()
    private static let marker = "session-valid"

    /// A read confirmed the session. The gate for anything that talks to UCB.
    var isSignedIn: Bool { phase == .signedIn }

    /// The launch session check hasn't answered yet.
    var isRestoring: Bool { phase == .checking }

    /// Optimistic: an on-device marker says this user was signed in, so cached
    /// tickets are worth showing. NOT a licence to hit the network — use
    /// `isSignedIn` for that.
    var hasSession: Bool { phase != .signedOut }

    /// Seed the phase from the on-device marker BEFORE any view renders.
    /// `restoreOnLaunch` used to be the first thing to set `.checking`, but it
    /// runs from a `.task` — frames after the Tickets tab has already drawn,
    /// and then only after a 1–20s web-view round trip. Starting at
    /// `.signedOut` is what made a returning user's wallet render the connect
    /// card over a Student ID that was already decoded in memory.
    ///
    /// `Keychain.string` is a synchronous `SecItemCopyMatching` — cheap enough
    /// for an initializer, at the cost of making the initial phase
    /// device-dependent (see `restoreOnLaunch`'s `defer` for the escape hatch).
    init() {
        if Keychain.string(for: Self.marker) == "1" { phase = .checking }
    }

    /// On launch: if we have a marker, confirm the session. Returns the outcome
    /// so `TicketStore` can adopt the same snapshot without a second load.
    ///
    /// No marker means we never asked UCB anything, so the outcome is `unknown`,
    /// NOT a definitive signed-out: reporting signed-out made every launch
    /// without a keychain marker wipe the ticket cache — including the fresh
    /// install that had just adopted `tickets.json` from iCloud, and with it
    /// the showtime reminders that cache arms. Phase stays `signedOut` (never
    /// seeded above), so the UI still shows the connect card.
    @discardableResult
    func restoreOnLaunch() async -> UCBSession.RefreshOutcome {
        guard phase == .checking else { return .unknown }
        // Marker present but the read was inconclusive (offline / interstitial /
        // task cancelled mid-launch): stay optimistically signed-in so cached
        // tickets show; a later refresh confirms or clears. As a `defer` rather
        // than an outcome check so no path can leave `.checking` dangling — a
        // stranded `.checking` is a permanent "Updating…" chip and no sign-out
        // button.
        defer { if phase == .checking { phase = .signedIn } }
        return await refresh()
    }

    /// Re-read the account. Applies identity on success, clears on a definitive
    /// signed-out, and leaves state untouched on an ambiguous read.
    @discardableResult
    func refresh() async -> UCBSession.RefreshOutcome {
        let outcome = await session.refresh()
        switch outcome {
        case .signedIn(let snap):
            phase = .signedIn
            name = snap.name; eligible = snap.eligible; freeRemaining = snap.freeRemaining
        case .signedOut:
            Keychain.delete(Self.marker)
            phase = .signedOut
            name = ""; eligible = false; freeRemaining = 0
        case .unknown:
            break
        }
        return outcome
    }

    /// Called by the sign-in web view once it lands on the logged-in dashboard.
    func completeSignIn() async {
        Keychain.set("1", for: Self.marker)
        let outcome = await refresh()
        // The user just watched the dashboard load, so an ambiguous first read
        // (challenge interstitial, slow network) must not leave the app looking
        // signed out — trust the login; the next refresh confirms.
        if case .unknown = outcome { phase = .signedIn }
    }

    func signOut() async {
        await session.signOut()
        Keychain.delete(Self.marker)
        phase = .signedOut
        name = ""; eligible = false; freeRemaining = 0
    }

    #if DEBUG
    /// Screenshot-verification hook (see DebugFixtures) — no session behind it.
    func debugForceSignedIn(name: String) {
        phase = .signedIn
        self.name = name; eligible = true; freeRemaining = 2
    }

    /// Screenshot-verification hook: hold the launch-restore phase open so the
    /// wallet's optimistic / "Updating…" state can actually be looked at. The
    /// one deliberate exception to "never strand `.checking`".
    func debugForceChecking() { phase = .checking }
    #endif
}
