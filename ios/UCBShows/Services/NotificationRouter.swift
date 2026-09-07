import Foundation
import UserNotifications

/// Handles taps on ticket, hearted-show and class-alert notifications. Ticket
/// taps route to the wallet (the max-brightness QR one step away); heart
/// reminders (a "showID" payload) to that show in the Tickets tab's I'm-Going
/// list; class-alert taps (CloudKit pushes carrying a "ck" payload) to the
/// Classes tab.
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

    /// Invoked when a class-alert push is tapped (buffered like onOpen).
    @MainActor var onClassAlert: (@MainActor () -> Void)? {
        didSet {
            if pendingClassAlert, let onClassAlert { pendingClassAlert = false; onClassAlert() }
        }
    }
    @MainActor private var pendingClassAlert = false

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
            await MainActor.run {
                if let onClassAlert { onClassAlert() } else { pendingClassAlert = true }
            }
        }
    }
}
