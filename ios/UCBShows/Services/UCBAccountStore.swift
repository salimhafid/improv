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

    /// On launch: if we have a marker, confirm the session is still live.
    func restoreOnLaunch() async {
        guard Keychain.string(for: Self.marker) == "1" else { return }
        phase = .checking
        _ = await refresh()
    }

    /// Re-read the account. Returns the snapshot (also consumed by TicketStore),
    /// or nil when the session has lapsed — in which case we fall back to
    /// signed-out and drop the marker so the UI prompts a fresh sign-in.
    @discardableResult
    func refresh() async -> UCBSession.AccountSnapshot? {
        let snap = await session.refresh()
        if let snap {
            phase = .signedIn
            name = snap.name
            eligible = snap.eligible
            freeRemaining = snap.freeRemaining
        } else {
            Keychain.delete(Self.marker)
            phase = .signedOut
            name = ""; eligible = false; freeRemaining = 0
        }
        return snap
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
