import Foundation

/// Explains settings that can prevent immediate, visible notification delivery.
/// No issues means these settings permit alerts; Focus and other system rules
/// can still silence them, so this is not a delivery or banner guarantee.
struct NotificationDeliveryStatus: Equatable {
    enum Authorization: Equatable {
        case notDetermined, denied, provisional, allowed
    }

    let authorization: Authorization
    let alertsEnabled: Bool
    let bannersEnabled: Bool
    let lockScreenEnabled: Bool
    let scheduledDelivery: Bool

    enum Issue: String, Identifiable {
        case permissionRequired
        case permissionDenied
        case quietAuthorization
        case bannersDisabled
        case lockScreenDisabled
        case scheduledDelivery

        var id: String { rawValue }

        var message: String {
            switch self {
            case .permissionRequired:
                return "Allow notifications for Improv to receive class alerts. Review notification permissions in Settings."
            case .permissionDenied:
                return "Notifications are off for Improv. Turn on Allow Notifications in Settings."
            case .quietAuthorization:
                return "Notifications are delivered quietly. Turn on Banners and Lock Screen for Improv in Settings."
            case .bannersDisabled:
                return "Banners are off for Improv. Turn on Banners in Settings to see alerts while using another app."
            case .lockScreenDisabled:
                return "Lock Screen alerts are off. Turn on Lock Screen for Improv in Settings."
            case .scheduledDelivery:
                return "Scheduled Summary can delay class alerts. Choose Immediate Delivery for Improv in Settings."
            }
        }
    }

    var issues: [Issue] {
        switch authorization {
        case .notDetermined: return [.permissionRequired]
        case .denied: return [.permissionDenied]
        case .provisional: return [.quietAuthorization]
        case .allowed:
            var issues: [Issue] = []
            if !alertsEnabled || !bannersEnabled { issues.append(.bannersDisabled) }
            if !lockScreenEnabled { issues.append(.lockScreenDisabled) }
            if scheduledDelivery { issues.append(.scheduledDelivery) }
            return issues
        }
    }
}
