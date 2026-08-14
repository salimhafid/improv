import Foundation
import UserNotifications

/// Handles taps on ticket notifications. A plain tap on iOS always foregrounds
/// the app (the QR itself is shown in the notification's expanded card via the
/// attachment); when the app does open, we route to the ticket so the
/// max-brightness scan surface is one step away.
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

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]   // still surface it if the app is foregrounded
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["ticketID"] as? String
        guard let id else { return }
        await MainActor.run {
            if let onOpen { onOpen(id) } else { pending = id }
        }
    }
}
