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
    private static let reminderLead: TimeInterval = 3 * 3600
    /// Keep a show listed until well after it has started (people arrive late,
    /// and "what was that show called?" outlives the start time by a bit).
    private static let expiryGrace: TimeInterval = 6 * 3600

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("UCBShows", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("going.json")
        load()
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
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Show].self, from: data) else { return }
        // Quietly drop shows that are long over.
        let cutoff = Date().addingTimeInterval(-Self.expiryGrace)
        shows = saved.filter { ($0.startDate ?? .distantFuture) > cutoff }
        ids = Set(shows.map(\.id))
        sort()
        if shows.count != saved.count { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shows) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func sort() {
        shows.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    // MARK: Reminders

    /// Best-effort local notification ~3h before showtime. Asks for permission on
    /// the first heart; if the user declines, hearting still works — there's just
    /// no reminder.
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
