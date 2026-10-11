import Foundation

// The pure decision behind the Class Alerts paywall: who gets alerts without
// paying, and when the app can't tell yet. Foundation-only (plus FeedService
// for the remote switch) so the logic harness pins every rule;
// `ClassAlertsAccess` feeds it StoreKit's answers.

/// Why Class Alerts are available on this device.
enum ClassAlertsUnlockReason: String, Equatable {
    /// The $9.99 non-consumable is among this Apple ID's current entitlements.
    case purchased
    /// The app was first downloaded before alerts went behind the paywall.
    case grandfathered
    /// A TestFlight/Xcode build with the remote `testflight_free` switch on.
    case testFlightFree
}

/// Whether Class Alerts may run. `unknown` is a real third answer, not a
/// pessimistic `locked`: a lock can delete the account's alert subscriptions
/// (how a refund takes effect — see `ClassAlertsStore.desired`), so a
/// transient StoreKit or network failure (an offline first launch, say) must
/// not be able to silence a grandfathered user. While unknown, the reconcile
/// neither creates nor deletes subscriptions.
enum ClassAlertsAccessState: Equatable {
    case unknown
    case locked
    case unlocked(ClassAlertsUnlockReason)
}

/// The StoreKit environment this build runs in (`AppTransaction.environment`),
/// with `unknown` for when it can't be read.
enum StoreEnvironmentKind: Equatable {
    /// Downloaded from the App Store.
    case production
    /// TestFlight (and sandbox-signed development installs).
    case sandbox
    /// Run from Xcode against `UCBShows.storekit`.
    case xcode
    case unknown
}

enum ClassAlertsAccessPolicy {
    /// The non-consumable IAP (not family-shareable) that unlocks Class Alerts.
    static let productID = "com.salimhafid.UCBShows.classalerts"
    /// The first build (1.8) that ships the paywall. Anyone whose original
    /// download is an earlier build keeps alerts free.
    static let firstPaywalledBuild = 28

    /// Whether the original download predates the paywall; nil = can't tell yet.
    ///
    /// Only production can grandfather: Apple documents that
    /// `originalAppVersion` is always "1.0" in the sandbox, so it says nothing
    /// about a TestFlight tester's real first download — sandbox and Xcode
    /// builds are definitively not grandfathered (the TestFlight switch below
    /// is how testers get alerts without paying). On iOS
    /// `originalAppVersion` is the CFBundleVersion of the first download, and
    /// every build so far is a plain integer; anything else can't be placed
    /// before build 28, so it is not grandfathered.
    static func isGrandfathered(originalAppVersion: String?, environment: StoreEnvironmentKind) -> Bool? {
        switch environment {
        case .sandbox, .xcode:
            return false
        case .unknown:
            return nil
        case .production:
            guard let originalAppVersion else { return nil }
            let trimmed = originalAppVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let build = Int(trimmed) else { return false }
            return build < firstPaywalledBuild
        }
    }

    /// Combines the inputs into an access state. `purchased`/`grandfathered`
    /// nil = unknown.
    ///
    /// A purchase always wins. The TestFlight switch only ever applies outside
    /// production, so flipping it can't give App Store users free alerts. A
    /// definitive `locked` needs a known "not purchased" plus either a known
    /// "not grandfathered" or a test environment (which can't grandfather);
    /// anything less certain stays `unknown`, which leaves subscriptions alone.
    static func decide(purchased: Bool?, grandfathered: Bool?, testFlightFree: Bool,
                       environment: StoreEnvironmentKind) -> ClassAlertsAccessState {
        if purchased == true { return .unlocked(.purchased) }
        let isTestEnvironment = environment == .sandbox || environment == .xcode
        if isTestEnvironment && testFlightFree { return .unlocked(.testFlightFree) }
        if grandfathered == true { return .unlocked(.grandfathered) }
        if purchased == false && (grandfathered == false || isTestEnvironment) { return .locked }
        return .unknown
    }
}

/// The remote switch in `docs/app-config.json` (served from the raw CDN):
/// `{"class_alerts": {"testflight_free": true}}` unlocks Class Alerts without
/// a purchase in TestFlight/Xcode builds, so the IAP can be taken out of the
/// way for testers without shipping a build.
///
/// Fails closed: any missing or wrong-typed value decodes as `false`, which is
/// the App Store behaviour (a JSON that doesn't parse at all throws, and
/// `testFlightFree(feed:cacheName:)` reads that as off too).
struct ClassAlertsRemoteConfig: Decodable, Equatable {
    var testFlightFree: Bool

    init(testFlightFree: Bool) {
        self.testFlightFree = testFlightFree
    }

    private enum RootKeys: String, CodingKey { case classAlerts = "class_alerts" }
    private enum ClassAlertsKeys: String, CodingKey { case testFlightFree = "testflight_free" }

    init(from decoder: Decoder) throws {
        let root = try? decoder.container(keyedBy: RootKeys.self)
        let classAlerts = try? root?.nestedContainer(keyedBy: ClassAlertsKeys.self, forKey: .classAlerts)
        testFlightFree = (try? classAlerts?.decode(Bool.self, forKey: .testFlightFree)) ?? false
    }

    /// The switch as the app resolves it from `feed`: the fresh copy; while
    /// the feed can't be reached, the last good copy; otherwise off. A copy
    /// that arrives but doesn't parse — a botched edit made to switch it off —
    /// is off as well, and drops the last good copy, so neither this launch
    /// nor a later offline one keeps testers unlocked on a stale `true`.
    static func testFlightFree(feed: URL, cacheName: String) async -> Bool {
        let service = FeedService<ClassAlertsRemoteConfig>(feed: feed, cacheName: cacheName)
        do {
            return try await service.fetchRemote().testFlightFree
        } catch is DecodingError {
            try? FileManager.default.removeItem(at: AppSupport.file(cacheName))
            return false
        } catch {
            return service.cachedPayload()?.testFlightFree ?? false
        }
    }
}
