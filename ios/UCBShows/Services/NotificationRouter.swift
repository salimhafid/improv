import CloudKit
import Foundation
import UserNotifications

/// A tapped class-alert push, reduced to what finding its class needs: the
/// `ClassAlert` record that fired it, and the subscription that matched
/// (which names the school — see `ClassAlertTarget.school(fromSubscriptionID:)`).
/// Either can be nil when the payload isn't a CloudKit query notification.
struct ClassAlertTap: Equatable {
    let recordName: String?
    let subscriptionID: String?
}

/// Handles taps on ticket, hearted-show and class-alert notifications. Ticket
/// taps route to the wallet (the max-brightness QR one step away); heart
/// reminders (a "showID" payload) to that show in the Tickets tab's I'm-Going
/// list; class-alert taps (CloudKit pushes carrying a "ck" payload) to that
/// class in the Classes tab.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// Set by the app; invoked on the main actor with the tapped ticket id.
    /// A tap that arrives before this is wired (cold launch from the lock
    /// screen — the delegate is installed in App.init, the closure in .task)
    /// is buffered and delivered on assignment.
    @MainActor var onOpen: (@MainActor (String) -> Void)? {
        didSet {
            if let id = pending, let onOpen { pending = nil; onOpen(id) }
        }
    }
    @MainActor private var pending: String?

    /// Invoked with the tapped heart reminder's show id (buffered like onOpen).
    @MainActor var onOpenShow: (@MainActor (String) -> Void)? {
        didSet {
            if let id = pendingShow, let onOpenShow { pendingShow = nil; onOpenShow(id) }
        }
    }
    @MainActor private var pendingShow: String?

    /// Invoked with a tapped class alert (buffered like onOpen; only the
    /// latest tap is kept — it is the one the user is looking for).
    @MainActor var onClassAlert: (@MainActor (ClassAlertTap) -> Void)? {
        didSet {
            if let tap = pendingClassAlert, let onClassAlert { pendingClassAlert = nil; onClassAlert(tap) }
        }
    }
    @MainActor private var pendingClassAlert: ClassAlertTap?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Still surface it if the app is foregrounded — and keep it in
        // Notification Center, so a banner missed mid-scroll isn't gone.
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let id = userInfo["ticketID"] as? String {
            await MainActor.run {
                if let onOpen { onOpen(id) } else { pending = id }
            }
        } else if let id = userInfo["showID"] as? String {
            await MainActor.run {
                if let onOpenShow { onOpenShow(id) } else { pendingShow = id }
            }
        } else if userInfo["ck"] != nil {
            let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification
            let tap = ClassAlertTap(recordName: query?.recordID?.recordName,
                                    subscriptionID: query?.subscriptionID)
            await MainActor.run {
                if let onClassAlert { onClassAlert(tap) } else { pendingClassAlert = tap }
            }
        }
    }

    // MARK: Class-alert record lookup

    private static let containerID = "iCloud.com.salimhafid.UCBShows"
    /// A tap is waiting on this. CloudKit's own resource timeout defaults to
    /// seven days, and before iOS 27 `record(for:)` ignores task
    /// cancellation, so the bound has to be the operation's configuration.
    private static let fetchTimeout: TimeInterval = 10

    /// Fetch the tapped alert's `ClassAlert` record from the public database
    /// and resolve `provisional` (same tap id) from it. The push itself only
    /// carries the record and subscription ids: the subscriptions'
    /// notification info is fixed to title/body/sound, and the record schema
    /// is fixed in production, so the record is the one place the class ids
    /// live. Any failure (no record id, offline, timeout, no such record)
    /// resolves to the provisional school with no ids, which the Classes tab
    /// treats as "open the school's folder".
    func resolve(_ tap: ClassAlertTap, provisional: ClassAlertTarget) async -> ClassAlertTarget {
        let unresolved = provisional.resolved(school: nil, classIDs: nil, pushBody: nil)
        guard let name = tap.recordName, !name.isEmpty else { return unresolved }
        // Built per lookup rather than stored: `CKContainer(identifier:)`
        // traps when the build lacks the iCloud entitlement, and as a stored
        // property the router (created in `UCBShowsApp.init`) would take the
        // whole app down with it — see `ClassAlertsStore.database`. Public
        // database reads need no iCloud account.
        let database = CKContainer(identifier: Self.containerID).publicCloudDatabase
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = Self.fetchTimeout
        configuration.timeoutIntervalForResource = Self.fetchTimeout
        do {
            let record = try await database.configuredWith(configuration: configuration) { db in
                try await db.record(for: CKRecord.ID(recordName: name))
            }
            return provisional.resolved(school: record["school"] as? String,
                                        classIDs: record["classIDs"] as? String,
                                        pushBody: record["pushBody"] as? String,
                                        alertedAt: record.creationDate)
        } catch {
            return unresolved
        }
    }
}
