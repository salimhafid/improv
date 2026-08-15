import Foundation
import Observation
import UserNotifications

/// The user's "I'm Going" list. Saved shows persist as full `Show` objects (not
/// just ids) so they stay renderable even after dropping out of the live feed,
/// and across all cities/theaters regardless of the current sidebar scope.
/// Hearting a show with a known start time also schedules a local reminder
/// notification a few hours before showtime.
@MainActor
@Observable
final class GoingStore {
    /// Saved shows, soonest first (undated last).
    private(set) var shows: [Show] = []

    private var ids: Set<String> = []
    private let fileURL: URL

    /// Lead time for the pre-show reminder notification.
    private static let reminderLead: TimeInterval = 3600
    /// Keep a show listed until well after it has started (people arrive late,
    /// and "what was that show called?" outlives the start time by a bit).
    private static let expiryGrace: TimeInterval = 6 * 3600

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
    }

    var count: Int { shows.count }

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
            scheduleReminder(for: show)
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
        // Re-schedule pending reminders so lead-time changes apply to shows
        // saved under an older lead (cancel + add is idempotent per show id).
        for show in shows {
            cancelReminder(for: show)
            scheduleReminder(for: show)
        }
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

    /// Best-effort local notification one hour before showtime. Asks for
    /// permission on the first heart; if the user declines, hearting still
    /// works — there's just no reminder.
    private func scheduleReminder(for show: Show) {
        guard let start = show.startDate else { return }
        let fireDate = start.addingTimeInterval(-Self.reminderLead)
        guard fireDate > Date() else { return }

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
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            try? await center.add(request)
        }
    }

    private func cancelReminder(for show: Show) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [show.id])
    }
}
