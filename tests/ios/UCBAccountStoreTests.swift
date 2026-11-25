import Foundation

// Deterministic device boundaries for the real UCBAccountStore. The harness
// uses neither WebKit website data nor the user's Keychain.
@MainActor enum Keychain {
    static var marker: String?
    static var accessible = true
    static func string(for key: String) -> String? { accessible ? marker : nil }
    static func set(_ value: String, for key: String) { if accessible { marker = value } }
    @discardableResult static func delete(_ key: String) -> Bool {
        if accessible { marker = nil }
        return accessible
    }
}

@MainActor final class UCBSession {
    struct AccountSnapshot: Equatable {
        let name: String
        var eligible = false
        var freeRemaining = 0
    }
    enum RefreshOutcome: Equatable {
        case signedIn(AccountSnapshot), signedOut, unknown
    }

    var cookies: () async -> Bool = { false }
    var snapshot: () async -> RefreshOutcome = { .unknown }
    var purge: () async -> Void = {}
    private(set) var reads = 0
    private(set) var purges = 0

    func hasLoginCookie() async -> Bool { await cookies() }
    func refresh() async -> RefreshOutcome { reads += 1; return await snapshot() }
    func signOut() async { purges += 1; await purge() }
}

@MainActor private final class Gate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?

    func hold() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while continuation == nil {
            precondition(clock.now < deadline, "operation failed to enter")
            await Task.yield()
        }
    }

    func resume(with value: Value) {
        let pending = continuation
        continuation = nil
        precondition(pending != nil)
        pending?.resume(returning: value)
    }
}

@main struct UCBAccountStoreTests {
    @MainActor static func main() async {
        typealias Outcome = UCBSession.RefreshOutcome
        let suite = "improv.tests.auth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = Outcome.signedIn(.init(name: "First fixture"))
        let second = Outcome.signedIn(.init(name: "Second fixture", eligible: true, freeRemaining: 1))
        let store = UCBAccountStore(defaults: defaults)
        var events: [Outcome] = []
        store.onRefresh = { events.append($0) }

        let fresh = await store.restoreOnLaunch()
        precondition(fresh == .unknown && store.phase == .signedOut && store.session.reads == 0 && events.isEmpty,
                     "a fresh install must leave its iCloud-restored wallet alone")

        // A first-party checkout can establish a session after an earlier
        // launch saw no marker or cookie. An offline page preserves local UI.
        store.session.cookies = { true }
        let unavailable = await store.restoreOnLaunch()
        precondition(unavailable == .unknown && store.isSignedIn && !store.isConfirmed && events.isEmpty)
        store.session.snapshot = { first }
        let verified = await store.refresh()
        precondition(verified == first && Keychain.marker == "1" && events == [first])
        precondition(store.isConfirmed && store.name == "First fixture")

        let read = Gate<Outcome>()
        store.session.snapshot = { await read.hold() }
        let staleRead = Task { await store.refresh() }
        await read.waitForEntry()
        let clear = Gate<Void>()
        store.session.purge = { await clear.hold() }
        let logout = Task { await store.signOut() }
        await clear.waitForEntry()
        precondition(store.phase == .signedOut && store.isSigningOut && !store.isConfirmed &&
                     Keychain.marker == nil && store.name.isEmpty && events == [first, .signedOut])
        let blockedLogin = await store.completeSignIn()
        precondition(blockedLogin == .unknown && Keychain.marker == nil)
        read.resume(with: first)
        let superseded = await staleRead.value
        precondition(superseded == .unknown && events == [first, .signedOut])
        clear.resume(with: ())
        await logout.value
        precondition(!store.isSigningOut && store.phase == .signedOut)

        let delayedCookie = Gate<Bool>()
        store.session.cookies = { await delayedCookie.hold() }
        let previousRestore = Task { await store.restoreOnLaunch() }
        await delayedCookie.waitForEntry()
        store.session.snapshot = { second }
        let login = await store.completeSignIn()
        delayedCookie.resume(with: true)
        let supersededRestore = await previousRestore.value
        precondition(login == second && supersededRestore == .unknown && store.name == "Second fixture")
        precondition(events == [first, .signedOut, second])

        let priorLogin = Gate<Outcome>()
        store.session.snapshot = { await priorLogin.hold() }
        let obsolete = Task { await store.completeSignIn() }
        await priorLogin.waitForEntry()
        store.session.snapshot = { second }
        _ = await store.completeSignIn()
        priorLogin.resume(with: .signedOut)
        let supersededLogin = await obsolete.value
        precondition(supersededLogin == .unknown && store.isConfirmed && store.eligible && Keychain.marker == "1")
        precondition(events == [first, .signedOut, second, second], "old login must not sign out the new account")

        let olderRead = Gate<Outcome>()
        store.session.snapshot = { await olderRead.hold() }
        let overlapping = Task { await store.refresh() }
        await olderRead.waitForEntry()
        store.session.snapshot = { second }
        _ = await store.refresh()
        olderRead.resume(with: .signedOut)
        let olderOutcome = await overlapping.value
        precondition(olderOutcome == .unknown && store.isConfirmed && events.last == second,
                     "an older read cannot sign out the account after a newer confirmed snapshot")

        let protected = UCBAccountStore(defaults: defaults)
        Keychain.accessible = false
        protected.session.purge = {}
        await protected.signOut()
        precondition(protected.isSigningOut && Keychain.marker == "1")
        let restarted = UCBAccountStore(defaults: defaults)
        precondition(restarted.phase == .signedOut && restarted.isSigningOut)
        restarted.session.cookies = { preconditionFailure("logout cleanup must precede cookie recovery") }
        Keychain.accessible = true
        let cleanup = await restarted.restoreOnLaunch()
        precondition(cleanup == .signedOut && !restarted.isSigningOut && Keychain.marker == nil &&
                     restarted.session.purges == 1 && restarted.session.reads == 0)

        Keychain.marker = "1"
        Keychain.accessible = false
        let locked = UCBAccountStore(defaults: defaults)
        let lockedRead = await locked.restoreOnLaunch()
        precondition(lockedRead == .unknown && locked.phase == .signedOut && locked.session.reads == 0)
        Keychain.accessible = true
        locked.session.snapshot = { second }
        let unlockedRead = await locked.restoreOnLaunch()
        precondition(unlockedRead == second && locked.isConfirmed,
                     "foreground should restore once protected device data is available")
        print("UCB account restoration, interrupted logout and stale-result tests passed")
    }
}
