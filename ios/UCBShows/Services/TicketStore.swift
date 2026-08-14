import Foundation
import Observation
import UserNotifications

/// The user's UCB tickets: reserved student tickets + the persistent standby
/// "UCB Student ID". Reads them from the account, persists full value objects
/// to Application Support (so QR renders offline), and keeps the near-venue
/// notifications + showtime reminders in sync — mirroring `GoingStore`.
@MainActor
@Observable
final class TicketStore {
    private(set) var reserved: [Ticket] = []
    private(set) var studentID: Ticket?

    /// Which UCB venues have shows today — set by the shows feed so the standby
    /// geofence only arms when standby is actually possible.
    var venuesWithShowsToday: Set<String> = []

    /// Set once at app composition (strong; no cycle back to us).
    var account: UCBAccountStore?

    private let proximity = TicketProximity()
    private let fileURL = AppSupport.file("tickets.json")

    init() {
        load()
        // Re-arm once location permission is actually granted (the first
        // reserve requests it, but arm() runs before the grant lands).
        proximity.onAuthorized = { [weak self] in
            Task { await self?.rearmGeofences() }
        }
    }

    var hasAnything: Bool { studentID != nil || !reserved.isEmpty }

    func ticket(id: String) -> Ticket? {
        if id == "studentID" { return studentID }
        return reserved.first { $0.id == id }
    }

    // MARK: Sync from the account

    /// Pull the latest tickets from UCB and re-arm everything.
    func sync() async {
        guard let account else { return }
        adopt(await account.refresh())
    }

    /// Apply a refresh outcome. `unknown` (transient / interstitial) is a no-op,
    /// so a bad read never wipes the offline cache or drops geofences.
    func adopt(_ outcome: UCBSession.RefreshOutcome) {
        switch outcome {
        case .signedIn(let snap): apply(snap)
        case .signedOut: clearLocal()
        case .unknown: break
        }
    }

    private func apply(_ snap: UCBSession.AccountSnapshot) {
        // UCB's account page doesn't expose showtimes, so `start` (which drives
        // reminders, expiry, and the release gate) is learned from the shows
        // feed at reserve time — carry it across syncs by order id.
        let prior = Dictionary(reserved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        reserved = snap.tickets.map { t in
            guard t.start == nil, let old = prior[t.id], old.start != nil else { return t }
            return Ticket(kind: .reserved, showID: old.showID, orderID: t.orderID,
                          eventID: t.eventID ?? old.eventID, title: t.title,
                          venueLabel: t.venueLabel, source: old.source,
                          start: old.start, qrSVG: t.qrSVG, releaseNonce: t.releaseNonce)
        }.filter { !$0.isPast() }
        studentID = snap.studentIDSVG.isEmpty
            ? nil
            : Ticket(kind: .studentID, title: "UCB Student ID", venueLabel: "",
                     source: "ucb_ny", qrSVG: snap.studentIDSVG, name: snap.name)
        save()
        reconcileReminders()
        Task { await rearmGeofences() }
    }

    /// Stamp the reserved ticket that matches this show with the show's start
    /// and identity (the account page carries neither). Best-effort: a ticket
    /// reserved on the UCB website instead of in-app simply keeps start == nil.
    private func adoptShowContext(_ show: Show) {
        guard let i = reserved.firstIndex(where: {
            $0.start == nil && $0.title.localizedCaseInsensitiveCompare(show.title) == .orderedSame
        }) else { return }
        let t = reserved[i]
        reserved[i] = Ticket(kind: .reserved, showID: show.id, orderID: t.orderID,
                             eventID: t.eventID, title: t.title, venueLabel: t.venueLabel,
                             source: show.source, start: show.start, qrSVG: t.qrSVG,
                             releaseNonce: t.releaseNonce)
        save()
        reconcileReminders()
        Task { await rearmGeofences() }
    }

    /// Drop all local ticket state + surfacing (sign-out / definitive signed-out).
    func clearLocal() {
        reserved = []
        studentID = nil
        save()
        armGeneration += 1   // invalidate any in-flight arm() so it can't re-add
        proximity.disarm()
        cancelAllReminders()
    }

    // MARK: Reserve / release (run inside the session web view)

    func reserve(show: Show) async -> UCBSession.ActionResult {
        guard let account, let url = show.url else {
            return .init(success: false, message: "Sign in to UCB to reserve.")
        }
        await proximity.requestAuthorization()
        let result = await account.session.reserve(showURL: url)
        if result.success {
            await sync()
            adoptShowContext(show)
        }
        return result
    }

    @discardableResult
    func release(_ ticket: Ticket) async -> Bool {
        guard let account, let order = ticket.orderID, let nonce = ticket.releaseNonce else { return false }
        let result = await account.session.release(order: order, nonce: nonce)
        if result.success { await sync() }
        return result.success
    }

    // MARK: Geofence + reminders

    /// Monotonic token ordering geofence arms against clearLocal(): arm()
    /// suspends for seconds rendering QR attachments, and a sign-out landing in
    /// that window must not let the resumed arm re-add the wiped account's QR.
    private var armGeneration = 0

    func rearmGeofences() async {
        armGeneration += 1
        let gen = armGeneration
        await proximity.arm(reserved: reserved, studentID: studentID,
                            venuesWithShows: venuesWithShowsToday,
                            isCurrent: { [weak self] in self?.armGeneration == gen })
    }

    private nonisolated static let reminderPrefix = "ticket/"

    /// Cancel reminders for tickets no longer held, (re)schedule the current set.
    private func reconcileReminders() {
        let center = UNUserNotificationCenter.current()
        let keep = Set(reserved.map { "\(Self.reminderPrefix)\($0.id)" })
        Task {
            let pending = await center.pendingNotificationRequests()
            let stale = pending.map(\.identifier)
                .filter { $0.hasPrefix(Self.reminderPrefix) && !keep.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        }
        for ticket in reserved {
            guard let start = ticket.startDate else { continue }
            let fireAt = start.addingTimeInterval(-3600)
            guard fireAt > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = ticket.title
            content.body = "Starts in an hour at \(Venue.forSource(ticket.source)?.name ?? "UCB")."
            content.sound = .default
            content.userInfo = ["ticketID": ticket.id]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(Self.reminderPrefix)\(ticket.id)",
                                             content: content, trigger: trigger))
        }
    }

    private func cancelAllReminders() {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    // MARK: Persistence

    private struct Saved: Codable { var reserved: [Ticket]; var studentID: Ticket? }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            AppSupport.moveAside(fileURL)
            return
        }
        reserved = saved.reserved.filter { !$0.isPast() }
        studentID = saved.studentID
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(reserved: reserved, studentID: studentID)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
