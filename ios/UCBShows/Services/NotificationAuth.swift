import Foundation
import UserNotifications

/// One place to ask for permission to notify, so the three notifying features —
/// hearted shows, held tickets, class alerts — can't drift apart.
///
/// Ask only when the user does something notifiable (hearts a show, reserves a
/// ticket, opens the wallet holding one, turns on class alerts), never at
/// launch. iOS presents the prompt once for the life of the install, so a
/// previous "Don't Allow" is respected in silence rather than re-asked.
enum NotificationAuth {
    /// Posted on the main thread the moment the user says yes. Requests
    /// submitted before authorization are rejected outright rather than queued,
    /// so whichever feature asked, every feature has to re-arm.
    static let didGrant = Notification.Name("NotificationAuth.didGrant")

    /// Where we stand today, without asking anything. The gate for the silent
    /// re-arm paths (launch, foreground) that must never raise a prompt.
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Prompts if the user has never been asked; reports whether the app may
    /// post notifications now.
    @discardableResult
    static func ensure() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            // Alert + sound only. The app posts no app-icon badge, and asking
            // for one would only surface a dead "Badges" toggle in Settings.
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted {
                await MainActor.run { NotificationCenter.default.post(name: didGrant, object: nil) }
            }
            return granted
        case .denied:
            return false
        default:
            return true   // authorized / provisional / ephemeral
        }
    }
}
