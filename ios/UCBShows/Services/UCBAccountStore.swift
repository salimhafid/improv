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

    var isSignedIn: Bool { phase == .signedIn }

    /// On launch: if we have a marker, confirm the session. Returns the outcome
    /// so `TicketStore` can adopt the same snapshot without a second load.
    @discardableResult
    func restoreOnLaunch() async -> UCBSession.RefreshOutcome {
        guard Keychain.string(for: Self.marker) == "1" else { return .signedOut }
        phase = .checking
        let outcome = await refresh()
        // Marker present but the read was inconclusive (offline / interstitial):
        // stay optimistically signed-in so cached tickets show; a later refresh
        // confirms or clears.
        if case .unknown = outcome { phase = .signedIn }
        return outcome
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
        _ = await refresh()
    }

    func signOut() async {
        await session.signOut()
        Keychain.delete(Self.marker)
        phase = .signedOut
        name = ""; eligible = false; freeRemaining = 0
    }
}
