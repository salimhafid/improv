import EventKit
import Foundation

/// Adds a show to the user's calendar with write-only access (the app never
/// reads existing events). Shows have no end time in the feed, so events get a
/// 90-minute default duration.
enum CalendarService {
    enum CalendarError: LocalizedError {
        case accessDenied
        case noStartTime

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Calendar access is off. You can allow it in Settings → Privacy → Calendars."
            case .noStartTime:
                return "This show doesn’t have a confirmed date yet."
            }
        }
    }

    private static let defaultDuration: TimeInterval = 90 * 60

    static func add(_ show: Show) async throws {
        guard let start = show.startDate else { throw CalendarError.noStartTime }

        let store = EKEventStore()
        guard try await store.requestWriteOnlyAccessToEvents() else {
            throw CalendarError.accessDenied
        }

        let event = EKEvent(eventStore: store)
        event.title = show.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(defaultDuration)
        event.timeZone = show.cityTimeZone
        let venue = show.shortVenue
        event.location = venue.isEmpty ? show.sourceLabel : "\(venue) · \(show.sourceLabel)"
        event.url = show.url
        if !show.excerpt.isEmpty { event.notes = show.excerpt }
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
