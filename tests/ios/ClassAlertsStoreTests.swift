import CloudKit
import Foundation
import UserNotifications

// The store runs unmodified against its real CKSubscription types. Only the
// services at the device/network boundary are replaced in this test executable.
@MainActor final class UIApplication {
    static let shared = UIApplication()
    private(set) var registrations = 0
    func registerForRemoteNotifications() { registrations += 1 }
}

enum PushRegistrationDelegate {
    static let didRegister = Notification.Name("test.push.registered")
    static let didFail = Notification.Name("test.push.failed")
}

@MainActor enum NotificationAuth {
    static let didGrant = Notification.Name("test.notifications.granted")
    static var authorization = NotificationDeliveryStatus.Authorization.allowed
    static func status() async -> UNAuthorizationStatus { .authorized }
    static func ensure() async -> Bool { true }
    static func deliveryStatus() async -> NotificationDeliveryStatus {
        .init(authorization: authorization, alertsEnabled: true, bannersEnabled: true,
              lockScreenEnabled: true, scheduledDelivery: false)
    }
}

@MainActor final class ClassAlertsAccess {
    enum Reason { case purchased, grandfathered }
    enum State: Equatable { case unlocked(Reason), locked, unknown }
    var state: State = .unlocked(.purchased)
    var isUnlocked: Bool {
        if case .unlocked = state { return true }
        return false
    }
    var isLocked: Bool { state == .locked }
}

@MainActor final class CKContainer {
    init(identifier: String) {}
    var publicCloudDatabase: TestDatabase { .shared }
}

@MainActor final class TestDatabase {
    static let shared = TestDatabase()
    var subscriptions = [CKSubscription.ID: CKSubscription]()
    var onSave: (() -> Void)?
    var onRead: (() throws -> Void)?
    var deleted = [String]()

    func configuredWith<R>(configuration: CKOperation.Configuration,
                           body: (TestDatabase) async throws -> R) async rethrows -> R {
        precondition(configuration.timeoutIntervalForResource > 0 && configuration.timeoutIntervalForResource <= 60)
        return try await body(self)
    }

    func allSubscriptions() async throws -> [CKSubscription] {
        let hook = onRead
        onRead = nil
        try hook?()
        return Array(subscriptions.values)
    }

    func modifySubscriptions(saving: [CKSubscription], deleting: [String]) async throws
        -> ([String: Result<CKSubscription, Error>], [String: Result<Void, Error>]) {
        for subscription in saving { subscriptions[subscription.subscriptionID] = subscription }
        for id in deleting { subscriptions.removeValue(forKey: id) }
        deleted += deleting
        if !saving.isEmpty {
            let hook = onSave
            onSave = nil
            hook?()
        }
        return (Dictionary(uniqueKeysWithValues: saving.map { ($0.subscriptionID, .success($0)) }),
                Dictionary(uniqueKeysWithValues: deleting.map { ($0, .success(())) }))
    }
}

@main struct ClassAlertsStoreTests {
    @MainActor static func expectEventually(_ reason: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition() {
            precondition(clock.now < deadline, reason)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let keys = ["classAlertPrefs", "classAlertSyncPending", "classAlertsRevokeOnLock"]
        for key in keys { defaults.removeObject(forKey: key) }
        defer { for key in keys { defaults.removeObject(forKey: key) } }

        let store = ClassAlertsStore()
        let access = ClassAlertsAccess()
        store.access = access
        let db = TestDatabase.shared
        let app = UIApplication.shared
        let magnet = "alert/magnet/all"
        let annoyance = "alert/annoyance/all"
        let logan = "alert/logan_square/all"
        var pending: Bool { defaults.bool(forKey: "classAlertSyncPending") }
        var subscriptions: Set<String> { Set(db.subscriptions.keys) }
        func applyCloudPrefs(schools: Set<String>) throws {
            var prefs = ClassAlertPreferences()
            prefs.master = true
            prefs.schools = schools
            defaults.set(try JSONEncoder().encode(prefs), forKey: "classAlertPrefs")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }

        try applyCloudPrefs(schools: ["magnet"])
        try await expectEventually("iCloud master-on must register this foreground device and subscribe") {
            subscriptions == [magnet] && app.registrations > 0 && !pending
        }

        NotificationAuth.authorization = .denied
        let registrations = app.registrations
        db.onRead = { throw URLError(.notConnectedToInternet) }
        store.setSchool("annoyance", enabled: true)
        try await expectEventually("an offline change retains its debt") { !store.syncIssue.isEmpty && pending }
        await store.armOnLaunch()
        precondition(subscriptions == [magnet, annoyance] && !pending && registrations == app.registrations,
                     "denying device permission must still allow a pending account change to retry")

        db.onRead = {
            store.setSchool("annoyance", enabled: true)
            throw URLError(.networkConnectionLost)
        }
        store.setSchool("annoyance", enabled: false)
        try await expectEventually("a failure for the obsolete plan must not strand the new one") {
            store.prefs.schools.contains("annoyance") && subscriptions == [magnet, annoyance] &&
                !pending && store.syncIssue.isEmpty
        }

        db.deleted = []
        db.onSave = { access.state = .unknown }
        try applyCloudPrefs(schools: ["logan_square"])
        try await expectEventually("the new subscription should have been saved") { subscriptions.contains(logan) }
        await store.syncSubscriptions()
        precondition(pending && db.deleted.isEmpty && subscriptions == [magnet, annoyance, logan],
                     "an uncertain entitlement during save must preserve existing subscriptions")

        access.state = .unlocked(.purchased)
        store.accessChanged()
        try await expectEventually("recovered access must finish replacing subscriptions") {
            subscriptions == [logan] && !pending
        }
        access.state = .locked
        store.accessChanged()
        try await expectEventually("a confirmed refund must revoke the installation's subscriptions") {
            subscriptions.isEmpty && !pending && !defaults.bool(forKey: "classAlertsRevokeOnLock")
        }
        print("Class alert registration and subscription recovery passed")
    }
}
