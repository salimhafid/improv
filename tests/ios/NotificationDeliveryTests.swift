import Foundation

func runNotificationDeliveryTests() {
    typealias Status = NotificationDeliveryStatus
    typealias Issue = Status.Issue

    // Authorization is the actionable first step. Contradictory or unavailable
    // per-channel settings must not bury it under several secondary warnings.
    let authorizationCases: [(Status.Authorization, Issue)] = [
        (.notDetermined, .permissionRequired),
        (.denied, .permissionDenied),
        (.provisional, .quietAuthorization),
    ]
    for (authorization, expected) in authorizationCases {
        let restricted = Status(authorization: authorization, alertsEnabled: false,
                                bannersEnabled: false, lockScreenEnabled: false,
                                scheduledDelivery: true)
        checkEqual(restricted.issues, [expected],
                   "\(authorization) takes precedence over channel and summary settings")
        let permitted = Status(authorization: authorization, alertsEnabled: true,
                               bannersEnabled: true, lockScreenEnabled: true,
                               scheduledDelivery: false)
        checkEqual(permitted.issues, [expected],
                   "\(authorization) remains actionable even when channel flags look enabled")
    }

    // Independent, explicit expectations for every combination ensure a banner
    // issue neither hides a separate Lock Screen / Summary issue nor duplicates
    // itself when both alert authorization and the banner style are disabled.
    let channelCases: [(alerts: Bool, banners: Bool, lockScreen: Bool, summary: Bool,
                        expected: [Issue])] = [
        (true, true, true, false, []),
        (true, true, true, true, [.scheduledDelivery]),
        (true, true, false, false, [.lockScreenDisabled]),
        (true, true, false, true, [.lockScreenDisabled, .scheduledDelivery]),
        (true, false, true, false, [.bannersDisabled]),
        (true, false, true, true, [.bannersDisabled, .scheduledDelivery]),
        (true, false, false, false, [.bannersDisabled, .lockScreenDisabled]),
        (true, false, false, true, [.bannersDisabled, .lockScreenDisabled, .scheduledDelivery]),
        (false, true, true, false, [.bannersDisabled]),
        (false, true, true, true, [.bannersDisabled, .scheduledDelivery]),
        (false, true, false, false, [.bannersDisabled, .lockScreenDisabled]),
        (false, true, false, true, [.bannersDisabled, .lockScreenDisabled, .scheduledDelivery]),
        (false, false, true, false, [.bannersDisabled]),
        (false, false, true, true, [.bannersDisabled, .scheduledDelivery]),
        (false, false, false, false, [.bannersDisabled, .lockScreenDisabled]),
        (false, false, false, true, [.bannersDisabled, .lockScreenDisabled, .scheduledDelivery]),
    ]
    for test in channelCases {
        let status = Status(authorization: .allowed, alertsEnabled: test.alerts,
                            bannersEnabled: test.banners, lockScreenEnabled: test.lockScreen,
                            scheduledDelivery: test.summary)
        checkEqual(status.issues, test.expected,
                   "delivery issues: alerts=\(test.alerts) banners=\(test.banners) lock=\(test.lockScreen) summary=\(test.summary)")
    }

    var latest = Status(authorization: .allowed, alertsEnabled: true, bannersEnabled: false,
                        lockScreenEnabled: false, scheduledDelivery: true)
    let restored = Status(authorization: .allowed, alertsEnabled: true, bannersEnabled: true,
                          lockScreenEnabled: true, scheduledDelivery: false)
    check(latest != restored, "a changed system settings snapshot is observable")
    latest = restored
    check(latest.issues.isEmpty, "a fresh allowed snapshot clears old settings warnings")

    let allIssues: [Issue] = [.permissionRequired, .permissionDenied, .quietAuthorization,
                              .bannersDisabled, .lockScreenDisabled, .scheduledDelivery]
    checkEqual(Set(allIssues.map(\.id)).count, allIssues.count,
               "simultaneous delivery issues have distinct stable UI identities")
    check(allIssues.allSatisfy { $0.message.contains("Settings") },
          "every delivery issue directs the user to Settings")
}
