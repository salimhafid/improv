import Foundation

private func remoteConfig(_ json: String) -> ClassAlertsRemoteConfig? {
    try? JSONDecoder().decode(ClassAlertsRemoteConfig.self, from: Data(json.utf8))
}

/// A fetched body's answer, as `ClassAlertsRemoteConfig.testFlightFree(feed:cacheName:)`
/// reads it: a body that doesn't parse at all is off, same as a missing key
/// (the resolution path itself is pinned in `testRemoteConfigResolution`).
private func testFlightFree(_ json: String) -> Bool {
    remoteConfig(json)?.testFlightFree ?? false
}

func runClassAlertsAccessTests() async {
    typealias Policy = ClassAlertsAccessPolicy
    let allEnvironments: [StoreEnvironmentKind] = [.production, .sandbox, .xcode, .unknown]

    checkEqual(Policy.productID, "com.salimhafid.UCBShows.classalerts", "IAP product id")
    checkEqual(Policy.firstPaywalledBuild, 28, "1.8 (build 28) is the first paywalled build")

    // Grandfathering reads the original download's build, in production only.
    checkEqual(Policy.isGrandfathered(originalAppVersion: "27", environment: .production), true,
               "first downloaded as build 27 is grandfathered")
    checkEqual(Policy.isGrandfathered(originalAppVersion: "1", environment: .production), true,
               "first downloaded as build 1 is grandfathered")
    checkEqual(Policy.isGrandfathered(originalAppVersion: "28", environment: .production), false,
               "first downloaded as build 28 pays")
    checkEqual(Policy.isGrandfathered(originalAppVersion: "120", environment: .production), false,
               "later builds compare numerically, not as strings")
    checkEqual(Policy.isGrandfathered(originalAppVersion: " 3 ", environment: .production), true,
               "surrounding whitespace is ignored")
    checkEqual(Policy.isGrandfathered(originalAppVersion: "1.0", environment: .production), false,
               "a non-integer build can't be placed before the paywall")
    checkEqual(Policy.isGrandfathered(originalAppVersion: "", environment: .production), false,
               "an empty build string is not grandfathered")
    checkEqual(Policy.isGrandfathered(originalAppVersion: nil, environment: .production), nil,
               "no original version yet is unknown, not false")
    for environment in [StoreEnvironmentKind.sandbox, .xcode] {
        checkEqual(Policy.isGrandfathered(originalAppVersion: "1", environment: environment), false,
                   "\(environment) never grandfathers (sandbox originalAppVersion is always 1.0)")
        checkEqual(Policy.isGrandfathered(originalAppVersion: nil, environment: environment), false,
                   "\(environment) is definitively not grandfathered even without a version")
    }
    checkEqual(Policy.isGrandfathered(originalAppVersion: "1", environment: .unknown), nil,
               "an unreadable environment can't decide grandfathering")
    checkEqual(Policy.isGrandfathered(originalAppVersion: nil, environment: .unknown), nil,
               "nothing known stays unknown")

    // A purchase beats every other input, including unknowns.
    for environment in allEnvironments {
        for grandfathered in [true, false, nil] as [Bool?] {
            for flag in [true, false] {
                checkEqual(Policy.decide(purchased: true, grandfathered: grandfathered,
                                         testFlightFree: flag, environment: environment),
                           .unlocked(.purchased),
                           "purchase wins: \(environment), grandfathered \(String(describing: grandfathered)), flag \(flag)")
            }
        }
    }

    // The TestFlight switch unlocks test environments only, whatever else is unknown.
    for environment in [StoreEnvironmentKind.sandbox, .xcode] {
        for purchased in [false, nil] as [Bool?] {
            checkEqual(Policy.decide(purchased: purchased, grandfathered: false,
                                     testFlightFree: true, environment: environment),
                       .unlocked(.testFlightFree),
                       "\(environment) with the switch on unlocks (purchased \(String(describing: purchased)))")
        }
        checkEqual(Policy.decide(purchased: false, grandfathered: false,
                                 testFlightFree: false, environment: environment),
                   .locked, "\(environment) with the switch off and no purchase is locked")
        checkEqual(Policy.decide(purchased: false, grandfathered: nil,
                                 testFlightFree: false, environment: environment),
                   .locked, "\(environment) can't grandfather, so unknown grandfathering still locks")
        checkEqual(Policy.decide(purchased: nil, grandfathered: false,
                                 testFlightFree: false, environment: environment),
                   .unknown, "\(environment) with purchases unreadable stays unknown")
    }
    checkEqual(Policy.decide(purchased: false, grandfathered: false,
                             testFlightFree: true, environment: .production),
               .locked, "production ignores the TestFlight switch")
    checkEqual(Policy.decide(purchased: false, grandfathered: nil,
                             testFlightFree: true, environment: .unknown),
               .unknown, "an unknown environment ignores the TestFlight switch")
    checkEqual(Policy.decide(purchased: false, grandfathered: false,
                             testFlightFree: true, environment: .unknown),
               .locked, "an unknown environment with known inputs ignores the switch and locks")

    // Grandfathering unlocks without a purchase; a definitive no locks.
    checkEqual(Policy.decide(purchased: false, grandfathered: true,
                             testFlightFree: false, environment: .production),
               .unlocked(.grandfathered), "grandfathered production install is unlocked")
    checkEqual(Policy.decide(purchased: nil, grandfathered: true,
                             testFlightFree: false, environment: .production),
               .unlocked(.grandfathered), "grandfathering doesn't wait for entitlements")
    checkEqual(Policy.decide(purchased: false, grandfathered: true,
                             testFlightFree: false, environment: .unknown),
               .unlocked(.grandfathered), "a cached grandfathered proof unlocks while StoreKit is unreadable")
    checkEqual(Policy.decide(purchased: false, grandfathered: false,
                             testFlightFree: false, environment: .production),
               .locked, "new production install without a purchase is locked")

    // Anything less than certain must not lock (a lock deletes subscriptions).
    checkEqual(Policy.decide(purchased: false, grandfathered: nil,
                             testFlightFree: false, environment: .production),
               .unknown, "production with grandfathering undetermined stays unknown")
    checkEqual(Policy.decide(purchased: false, grandfathered: nil,
                             testFlightFree: false, environment: .unknown),
               .unknown, "offline first launch stays unknown")
    checkEqual(Policy.decide(purchased: nil, grandfathered: false,
                             testFlightFree: false, environment: .production),
               .unknown, "unreadable entitlements stay unknown even when not grandfathered")
    checkEqual(Policy.decide(purchased: nil, grandfathered: nil,
                             testFlightFree: false, environment: .unknown),
               .unknown, "nothing known stays unknown")

    // The remote switch decodes leniently and fails closed.
    checkEqual(remoteConfig(#"{"class_alerts": {"testflight_free": true}}"#),
               ClassAlertsRemoteConfig(testFlightFree: true), "switch on decodes")
    checkEqual(remoteConfig(#"{"class_alerts": {"testflight_free": false}}"#),
               ClassAlertsRemoteConfig(testFlightFree: false), "switch off decodes")
    checkEqual(remoteConfig(#"{"class_alerts": {"testflight_free": true}, "future": {"x": 1}}"#)?.testFlightFree,
               true, "unrelated keys are ignored")
    checkEqual(testFlightFree(#"{"class_alerts": {}}"#), false, "missing testflight_free is off")
    checkEqual(testFlightFree(#"{"other": {"testflight_free": true}}"#), false, "missing class_alerts is off")
    checkEqual(testFlightFree(#"{"class_alerts": {"testflight_free": "true"}}"#), false, "a string is not a Bool")
    checkEqual(testFlightFree(#"{"class_alerts": {"testflight_free": 1}}"#), false, "a number is not a Bool")
    checkEqual(testFlightFree(#"{"class_alerts": {"testflight_free": null}}"#), false, "null is off")
    checkEqual(testFlightFree(#"{"class_alerts": true}"#), false, "a wrong-typed class_alerts is off")
    checkEqual(testFlightFree(#"{}"#), false, "an empty object is off")
    checkEqual(testFlightFree(#"[]"#), false, "a non-object payload is off")
    checkEqual(testFlightFree("<html>404: Not Found</html>"), false, "garbage is off")
    checkEqual(testFlightFree(""), false, "an empty body is off")

    // The served config must spell the switch exactly as the app reads it —
    // a typo would silently read as off. Either value is a valid state.
    if let data = try? Data(contentsOf: URL(fileURLWithPath: "docs/app-config.json")) {
        let strict = try? JSONDecoder().decode(StrictAppConfig.self, from: data)
        check(strict != nil, "docs/app-config.json has class_alerts.testflight_free as a JSON Bool")
        checkEqual(remoteConfig(String(decoding: data, as: UTF8.self))?.testFlightFree,
                   strict?.class_alerts.testflight_free, "the app reads docs/app-config.json's switch")
    } else {
        check(false, "docs/app-config.json is readable from the repo root")
    }

    await testRemoteConfigResolution()
}

/// The fetch → last-good-copy → off chain, driven by a file:// feed (a
/// missing file is an unreachable feed, a present one a 200 body).
private func testRemoteConfigResolution() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("improv_access_tests_\(ProcessInfo.processInfo.processIdentifier)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let feed = dir.appendingPathComponent("app-config.json")
    let cacheName = "logic_tests.app-config.cache.json"
    try? FileManager.default.removeItem(at: AppSupport.file(cacheName))
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: AppSupport.file(cacheName))
    }
    func resolve() async -> Bool {
        await ClassAlertsRemoteConfig.testFlightFree(feed: feed, cacheName: cacheName)
    }
    func serve(_ body: String) { try! Data(body.utf8).write(to: feed) }
    func unreachable() { try? FileManager.default.removeItem(at: feed) }

    unreachable()
    checkEqual(await resolve(), false, "no feed and no cached copy is off")

    serve(#"{"class_alerts": {"testflight_free": true}}"#)
    checkEqual(await resolve(), true, "a served true is on")
    unreachable()
    checkEqual(await resolve(), true, "an unreachable feed keeps the last good copy")

    serve(#"{"class_alerts": {"testflight_free": false}}"#)
    checkEqual(await resolve(), false, "a served false is off")
    unreachable()
    checkEqual(await resolve(), false, "…and that false is the copy kept")

    serve(#"{"class_alerts": {"testflight_free": true}}"#)
    _ = await resolve()
    serve(#"{"class_alerts": {"testflight_free": false},}"#)   // a botched switch-off
    checkEqual(await resolve(), false, "a body that doesn't parse is off, not the cached true")
    unreachable()
    checkEqual(await resolve(), false, "…and drops the cached true, so offline stays off")

    serve(#"{"class_alerts": {"testflight_free": true}}"#)
    _ = await resolve()
    serve("<html>404: Not Found</html>")
    checkEqual(await resolve(), false, "a non-JSON 200 body is off")
    serve(#"{"class_alerts": {"testflight_free": "yes"}}"#)
    checkEqual(await resolve(), false, "a wrong-typed switch is off")
}

/// docs/app-config.json's shape, without the app decoder's leniency.
private struct StrictAppConfig: Decodable {
    struct ClassAlerts: Decodable { let testflight_free: Bool }
    let class_alerts: ClassAlerts
}
