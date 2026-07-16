import EventKit
import Foundation

/// The user's preferred calendar destination, chosen on first use of
/// "Add to Calendar" and remembered (stored via @AppStorage).
enum CalendarProvider: String {
    case apple, google
}

/// Adds a show to the user's calendar. Apple Calendar goes through EventKit
/// with write-only access (the app never reads existing events); Google
/// Calendar opens the event-template deep link, which routes to the Google
/// Calendar app when installed (or calendar.google.com otherwise). Shows have
/// no end time in the feed, so events get a 90-minute default duration.
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

    /// Google Calendar "create event" template URL for a show, with times sent
    /// as floating venue-local stamps pinned by the ctz parameter.
    static func googleCalendarURL(for show: Show) -> URL? {
        guard let start = show.startDate else { return nil }
        let end = start.addingTimeInterval(defaultDuration)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = show.cityTimeZone
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"

        let venue = show.shortVenue
        let location = venue.isEmpty ? show.sourceLabel : "\(venue) · \(show.sourceLabel)"
        var details = show.excerpt
        if let url = show.url {
            details += (details.isEmpty ? "" : "\n\n") + url.absoluteString
        }

        var components = URLComponents(string: "https://calendar.google.com/calendar/render")!
        components.queryItems = [
            .init(name: "action", value: "TEMPLATE"),
            .init(name: "text", value: show.title),
            .init(name: "dates", value: "\(stamp.string(from: start))/\(stamp.string(from: end))"),
            .init(name: "ctz", value: show.cityTimeZone.identifier),
            .init(name: "location", value: location),
            .init(name: "details", value: details),
        ]
        return components.url
    }
}
