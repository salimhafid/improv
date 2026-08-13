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
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("UCBShows", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tickets.json")
        load()
    }

    var hasAnything: Bool { studentID != nil || !reserved.isEmpty }

    func ticket(id: String) -> Ticket? {
        if id == "studentID" { return studentID }
        return reserved.first { $0.id == id }
    }

    // MARK: Sync from the account

    /// Pull the latest tickets from UCB and re-arm everything. Called on launch,
    /// after reserve/release, and on foreground.
    func sync() async {
        guard let account else { return }
        guard let snap = await account.refresh() else {
            reserved = []; studentID = nil; save()
            proximity.disarm()
            return
        }
        apply(snap)
    }

    private func apply(_ snap: UCBSession.AccountSnapshot) {
        reserved = snap.tickets.filter { !$0.isPast() }
        studentID = snap.studentIDSVG.isEmpty
            ? nil
            : Ticket(kind: .studentID, title: "UCB Student ID", venueLabel: "",
                     source: "ucb_ny", qrSVG: snap.studentIDSVG, name: snap.name)
        save()
        scheduleReminders()
        Task { await rearmGeofences() }
    }

    // MARK: Reserve / release (run inside the session web view)

    func reserve(show: Show) async -> UCBSession.ActionResult {
        guard let account, let url = show.url else {
            return .init(success: false, message: "Sign in to UCB to reserve.")
        }
        await proximity.requestAuthorization()
        // One atomic session op: load the show, read the live claim control, claim.
        let result = await account.session.reserve(showURL: url)
        if result.success { await sync() }
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

    func rearmGeofences() async {
        await proximity.arm(reserved: reserved, studentID: studentID,
                            venuesWithShows: venuesWithShowsToday)
    }

    private func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        let ids = reserved.map { "ticket/\($0.id)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
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
            center.add(UNNotificationRequest(identifier: "ticket/\(ticket.id)",
                                             content: content, trigger: trigger))
        }
    }

    // MARK: Persistence

    private struct Saved: Codable { var reserved: [Ticket]; var studentID: Ticket? }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            let bak = fileURL.deletingPathExtension().appendingPathExtension("bak.json")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.moveItem(at: fileURL, to: bak)
            return
        }
        reserved = saved.reserved.filter { !$0.isPast() }
        studentID = saved.studentID
    }

    private func save() {
        let payload = Saved(reserved: reserved, studentID: studentID)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
