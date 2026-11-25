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

    /// A real `.signedIn` read landed this session, so `name` / `eligible` /
    /// `freeRemaining` describe the account rather than their defaults.
    /// `phase == .signedIn` is NOT that: launch restore and sign-in both force
    /// `.signedIn` on an inconclusive read, and "0 free shows left" off a
    /// default is a lie the wallet must not print.
    private(set) var isConfirmed = false

    /// Deliver a validated wallet change in the same main-actor turn as the
    /// identity change. A caller resuming after an await may already belong to
    /// a newer login or an explicit sign-out.
    @ObservationIgnored var onRefresh: ((UCBSession.RefreshOutcome) -> Void)?
    private(set) var isSigningOut = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var readSequence: UInt64 = 0
    @ObservationIgnored private var lastAppliedRead: UInt64 = 0
    @ObservationIgnored private var restoringGeneration: UInt64?
    @ObservationIgnored private var signOutTask: Task<Void, Never>?
    private let defaults: UserDefaults
    // A local cleanup flag, deliberately outside CloudSync's mirrored keys.
    private static let pendingSignOut = "ucbSignOutPending"

    let session = UCBSession()
    private static let marker = "session-valid"

    /// Ready to use or revalidate the session. An offline restoration can
    /// reach this phase before identity and eligibility are confirmed.
    var isSignedIn: Bool { phase == .signedIn }

    /// The launch session check hasn't answered yet.
    var isRestoring: Bool { phase == .checking }

    /// Optimistic: an on-device marker says this user was signed in, so cached
    /// tickets are worth showing. NOT a licence to hit the network — use
    /// `isSignedIn` for that.
    var hasSession: Bool { phase != .signedOut }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSigningOut = defaults.bool(forKey: Self.pendingSignOut)
        if !isSigningOut, Keychain.string(for: Self.marker) == "1" { phase = .checking }
    }

    /// Called at launch, on foreground and after first-party web browsing. A
    /// visitor without either a marker or a WebKit login cookie has no local
    /// session to verify. Leave their iCloud-restored tickets alone, and check
    /// again next time in case Keychain was temporarily locked or they logged
    /// in through another page in the shared WebKit store.
    @discardableResult
    func restoreOnLaunch() async -> UCBSession.RefreshOutcome {
        if defaults.bool(forKey: Self.pendingSignOut) {
            await signOut()
            return .signedOut
        }
        guard phase != .signedIn, !isSigningOut, restoringGeneration != generation else { return .unknown }
        let current = generation
        restoringGeneration = current
        defer { if restoringGeneration == current { restoringGeneration = nil } }
        if phase != .checking, Keychain.string(for: Self.marker) != "1" {
            let hasCookie = await session.hasLoginCookie()
            guard current == generation, hasCookie else { return .unknown }
        }
        return await confirmSession(current)
    }

    /// A previous local sign-in or a verified dashboard permits showing
    /// cached tickets after an inconclusive read. A server-confirmed logout
    /// and an explicit logout both take precedence over that fallback.
    private func confirmSession(_ current: UInt64) async -> UCBSession.RefreshOutcome {
        guard current == generation, !isSigningOut else { return .unknown }
        phase = .checking
        let outcome = await refresh()
        guard current == generation else { return .unknown }
        if phase == .checking { phase = .signedIn }
        return outcome
    }

    @discardableResult
    func refresh() async -> UCBSession.RefreshOutcome {
        guard hasSession, !isSigningOut else { return .unknown }
        let current = generation
        readSequence += 1
        let read = readSequence
        let outcome = await session.refresh()
        guard current == generation, read > lastAppliedRead else { return .unknown }
        switch outcome {
        case .signedIn(let snap):
            rememberSession()
            phase = .signedIn
            isConfirmed = true
            name = snap.name; eligible = snap.eligible; freeRemaining = snap.freeRemaining
        case .signedOut:
            Keychain.delete(Self.marker)
            clearIdentity()
        case .unknown:
            return .unknown
        }
        lastAppliedRead = read
        onRefresh?(outcome)
        return outcome
    }

    private func rememberSession() {
        if Keychain.string(for: Self.marker) != "1" { Keychain.set("1", for: Self.marker) }
    }

    /// The login sheet already saw a verified first-party dashboard. Invalidate
    /// every read started under the old identity before confirming this one.
    @discardableResult
    func completeSignIn() async -> UCBSession.RefreshOutcome {
        guard !isSigningOut else { return .unknown }
        generation += 1
        let current = generation
        restoringGeneration = current
        defer { if restoringGeneration == current { restoringGeneration = nil } }
        clearIdentity()
        rememberSession()
        return await confirmSession(current)
    }

    private func clearIdentity() {
        phase = .signedOut
        isConfirmed = false
        name = ""; eligible = false; freeRemaining = 0
    }

    func signOut() async {
        if let task = signOutTask { await task.value; return }
        generation += 1
        isSigningOut = true
        // If iOS terminates us before WebKit finishes, resume erasing the
        // previous session on launch before considering any surviving cookie.
        defaults.set(true, forKey: Self.pendingSignOut)
        clearIdentity()
        onRefresh?(.signedOut)
        let removedMarker = Keychain.delete(Self.marker)
        let task = Task {
            await session.signOut()
            // The marker can be inaccessible before the device's first unlock.
            // Keep cleanup pending then, so it cannot seed a new cached login.
            if removedMarker || Keychain.delete(Self.marker) {
                defaults.removeObject(forKey: Self.pendingSignOut)
                isSigningOut = false
            }
            signOutTask = nil
        }
        signOutTask = task
        await task.value
    }

    #if DEBUG
    /// Screenshot-verification hook (see DebugFixtures) — no session behind it.
    func debugForceSignedIn(name: String) {
        phase = .signedIn
        isConfirmed = true
        self.name = name; eligible = true; freeRemaining = 2
    }

    /// Screenshot-verification hook: hold the launch-restore phase open so the
    /// wallet's optimistic / "Updating…" state can actually be looked at. The
    /// one deliberate exception to "never strand `.checking`".
    func debugForceChecking() { phase = .checking }
    #endif
}
