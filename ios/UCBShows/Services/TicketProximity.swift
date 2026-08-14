import CoreLocation
import Foundation
import UserNotifications

/// Arms the near-venue notifications. Uses `UNLocationNotificationTrigger`,
/// which needs only When-In-Use location and is monitored by the system even
/// when the app is terminated. The QR rides along as a PNG attachment so it
/// shows in the (expanded) notification without launching the app.
@MainActor
final class TicketProximity: NSObject, CLLocationManagerDelegate {
    static let category = "UCB_TICKET"

    private let manager = CLLocationManager()
    private(set) var locationStatus: CLAuthorizationStatus

    /// Invoked when location authorization first becomes usable, so the store
    /// can arm geofences it couldn't at reserve time (auth is granted async,
    /// after `arm()` has already run and no-op'd on the `ready` guard).
    var onAuthorized: (() -> Void)?

    override init() {
        locationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Ask for notification + When-In-Use location the first time a ticket is
    /// held (lazy, like the I'm-Going reminders).
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    private var ready: Bool {
        locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways
    }

    /// (Re)arm one region per venue. Content is chosen now (the trigger bakes
    /// it at schedule time): a reserved ticket at that venue wins; otherwise the
    /// standby student ID, but only where the venue actually has shows today.
    /// `isCurrent` is re-checked after every suspension so an arm superseded
    /// mid-flight (sign-out, newer arm) never adds anything.
    func arm(reserved: [Ticket], studentID: Ticket?, venuesWithShows: Set<String>,
             isCurrent: () -> Bool = { true }) async {
        let center = UNUserNotificationCenter.current()
        let venueIDs = Venue.all.map { "geofence/\($0.id)" }
        center.removePendingNotificationRequests(withIdentifiers: venueIDs)
        guard ready else { return }

        for venue in Venue.all {
            let reservedHere = reserved
                .filter { $0.source == venue.id && !$0.isPast() }
                .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

            let ticket: Ticket
            let body: String
            if let t = reservedHere.first {
                ticket = t
                body = "Tap to show your ticket for \(t.title)."
            } else if let sid = studentID, venuesWithShows.contains(venue.id) {
                ticket = sid
                body = "Tap to show your student ID for standby entry."
            } else {
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = "You’re near \(venue.name)"
            content.body = body
            content.categoryIdentifier = Self.category
            content.userInfo = ["ticketID": ticket.id]
            content.sound = .default

            if let png = await QRRender.rasterize(svg: ticket.qrSVG),
               let url = Self.writeTemp(png, name: venue.id),
               let att = try? UNNotificationAttachment(
                   identifier: "qr", url: url,
                   options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false]) {
                content.attachments = [att]
            }
            guard isCurrent() else { return }   // superseded while rendering

            let trigger = UNLocationNotificationTrigger(region: venue.region, repeats: false)
            let req = UNNotificationRequest(identifier: "geofence/\(venue.id)",
                                            content: content, trigger: trigger)
            try? await center.add(req)
            guard isCurrent() else {            // superseded during add — undo
                center.removePendingNotificationRequests(withIdentifiers: ["geofence/\(venue.id)"])
                return
            }
        }
    }

    /// Drop all armed venue notifications (e.g. on sign-out).
    func disarm() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Venue.all.map { "geofence/\($0.id)" })
    }

    private static func writeTemp(_ png: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ucb-qr-\(name).png")
        do { try png.write(to: url, options: .atomic); return url } catch { return nil }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let becameUsable = !self.ready
                && (status == .authorizedWhenInUse || status == .authorizedAlways)
            self.locationStatus = status
            if becameUsable { self.onAuthorized?() }
        }
    }
}
