import Foundation
import Observation
import UserNotifications

/// The user's "I'm Going" list. Saved shows persist as full `Show` objects (not
/// just ids) so they stay renderable even after dropping out of the live feed,
/// and across all cities/theaters regardless of the current sidebar scope.
/// Hearting a show with a known start time also schedules a local reminder
/// notification an hour before showtime — unless the user holds a ticket to
/// that show, in which case `TicketStore` owns the reminder and this one stands
/// down, so one show never posts two banners.
@MainActor
@Observable
final class GoingStore {
    /// Saved shows, soonest first (undated last).
    private(set) var shows: [Show] = []

    private var ids: Set<String> = []
    private let fileURL: URL

    /// Keep a show listed until well after it has started (people arrive late,
    /// and "what was that show called?" outlives the start time by a bit).
    private static let expiryGrace: TimeInterval = 6 * 3600

    /// What the user's held tickets already cover, published by `TicketStore`.
    /// Its reminder wins (tapping it opens the QR at the door), so those shows
    /// get no heart reminder of their own.
    private var coverage = ReminderCoverage()

    init() {
        fileURL = AppSupport.file("going.json")
        load()
        // Another device changed the list via iCloud — reload it live.
        NotificationCenter.default.addObserver(
            forName: CloudSync.fileDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard note.object as? String == "going.json" else { return }
            MainActor.assumeIsolated { self?.load() }
        }
        // Whichever feature obtained the grant, ours has to re-arm: anything
        // we tried to schedule while unauthorized was rejected, not queued.
        NotificationCenter.default.addObserver(
            forName: NotificationAuth.didGrant, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.armReminders() }
        }
    }

    func isGoing(_ show: Show) -> Bool { ids.contains(show.id) }

    func toggle(_ show: Show) {
        if ids.contains(show.id) {
            ids.remove(show.id)
            shows.removeAll { $0.id == show.id }
            cancelReminder(for: show)
        } else {
            ids.insert(show.id)
            shows.append(show)
            sort()
            // A heart is a notifiable action, so this is where we ask.
            scheduleReminder(for: show, ask: true)
        }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let saved = try? JSONDecoder().decode([Show].self, from: data) else {
            // The file exists but won't decode. Starting empty is fine, but the
            // next toggle()'s save() would then overwrite the user's whole list
            // with one show — park the unreadable file aside first so the data
            // survives for a future recovery/migration.
            AppSupport.moveAside(fileURL)
            return
        }
        // Quietly drop shows that are long over.
        let cutoff = Date().addingTimeInterval(-Self.expiryGrace)
        shows = saved.filter { ($0.startDate ?? .distantFuture) > cutoff }
        ids = Set(shows.map(\.id))
        sort()
        if shows.count != saved.count { save() }
        armReminders()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shows) {
            try? data.write(to: fileURL, options: .atomic)
            CloudSync.pushFile("going.json", data)
        }
    }

    private func sort() {
        shows.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    // MARK: Reminders

    /// (Re)arm every hearted show, silently. Runs at launch, when the lead time
    /// changes, and whenever the held-ticket set moves — none of which are
    /// moments to raise a permission prompt, so the adds simply no-op if
    /// permission was never granted; the next heart or reserve is what asks.
    func armReminders() {
        for show in shows {
            cancelReminder(for: show)
            scheduleReminder(for: show)
        }
    }

    /// Published by `TicketStore` whenever the held-ticket set changes.
    /// Re-arming everything is what makes the suppression reversible: release
    /// the ticket and the hearted show's own reminder comes back.
    func setTicketCoverage(_ new: ReminderCoverage) {
        guard new != coverage else { return }
        coverage = new
        armReminders()
    }

    /// Best-effort local notification one hour before showtime. `ask` is true
    /// only for a fresh heart — the user-initiated moment where a permission
    /// prompt has obvious context. If the user declines, hearting still
    /// works — there's just no reminder.
    private func scheduleReminder(for show: Show, ask: Bool = false) {
        guard let start = show.startDate,
              let fireDate = ReminderPlan.fireDate(forStart: start) else { return }
        // One reminder per show: when the user holds a ticket to this one,
        // `TicketStore` owns the reminder (tapping it opens the QR at the
        // door). A fresh heart still asks for permission in that case — the
        // ticket's reminder is exactly what the grant unblocks, and the ticket
        // store re-arms it on `NotificationAuth.didGrant`.
        let ticketed = coverage.covers(showID: show.id, title: show.title, start: show.startDate)
        guard ask || !ticketed else { return }

        let content = UNMutableNotificationContent()
        content.title = show.title
        var whereAt = show.shortVenue.isEmpty ? show.org : show.shortVenue
        if whereAt.isEmpty { whereAt = show.sourceLabel }
        content.body = "Starts at \(show.timeLabel) · \(whereAt)"
        content.sound = .default

        let interval = fireDate.timeIntervalSinceNow
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: show.id, content: content, trigger: trigger)

        Task {
            if ask, await NotificationAuth.ensure() == false { return }
            // Re-read coverage rather than trusting the value captured above:
            // the user can sit on the permission alert long enough for the
            // ticket to land, and adding this request afterwards would post a
            // second banner for a show `TicketStore` is already reminding about.
            guard !coverage.covers(showID: show.id, title: show.title, start: show.startDate) else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func cancelReminder(for show: Show) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [show.id])
    }
}
