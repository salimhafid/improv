import Foundation

/// The shared math behind every pre-show reminder — hearted shows and held
/// tickets alike. Pure Foundation plus the `Show` model (no UserNotifications,
/// no UIKit) so it stays unit-testable in the offline logic harness.
enum ReminderPlan {
    /// How long before showtime a reminder fires.
    static let lead: TimeInterval = 3600

    /// When the reminder for a show starting at `start` should fire, or nil if
    /// that moment has already passed (nothing left to schedule).
    static func fireDate(forStart start: Date, now: Date = Date()) -> Date? {
        let fire = start.addingTimeInterval(-lead)
        return fire > now ? fire : nil
    }

    /// Do a held ticket and a hearted show describe the same night out? Only
    /// needed when the ticket carries no `showID` — reserved on ucbtheatre.com,
    /// or restored from iCloud before the join was stamped. Same title, same
    /// start give or take a minute, because the shows feed and the account page
    /// round showtimes differently.
    static func sameEvent(_ aTitle: String, _ aStart: Date?,
                          _ bTitle: String, _ bStart: Date?) -> Bool {
        guard let aStart, let bStart else { return false }
        return aTitle.localizedCaseInsensitiveCompare(bTitle) == .orderedSame
            && abs(aStart.timeIntervalSince(bStart)) < 60
    }

    /// The join used to stamp a freshly reserved ticket with the show it came
    /// from: same title on the same venue-local night, so a recurring
    /// same-titled show (ASSSSCAT every Sunday) can't stamp the wrong ticket.
    /// A ticket whose start didn't parse matches on title alone — it's the one
    /// we just created, and the show is where its start would come from.
    static func sameBooking(ticketTitle: String, ticketStart: Date?,
                            showTitle: String, showStart: Date?,
                            in tz: TimeZone) -> Bool {
        guard ticketTitle.localizedCaseInsensitiveCompare(showTitle) == .orderedSame else {
            return false
        }
        guard let ticketStart else { return true }
        guard let showStart else { return false }
        return DateUtils.calendar(in: tz).isDate(ticketStart, inSameDayAs: showStart)
    }

    /// The one show in `shows` a held ticket belongs to, or nil when the feed
    /// offers no match — or more than one. This is the backfill join for
    /// tickets that never passed through the in-app reserve: bought on
    /// ucbtheatre.com, or restored from iCloud before the join was stamped.
    /// Same title on the same venue-local night, with an exact showtime
    /// breaking a double bill. Ambiguity deliberately stays unjoined: stamping
    /// the wrong id would stand the wrong hearted show's reminder down, and the
    /// user would miss a show instead of merely getting two banners.
    static func uniqueBooking(ticketTitle: String, ticketStart: Date?,
                              in shows: [Show]) -> Show? {
        guard ticketStart != nil else { return nil }
        let sameNight = shows.filter {
            sameBooking(ticketTitle: ticketTitle, ticketStart: ticketStart,
                        showTitle: $0.title, showStart: $0.startDate, in: $0.cityTimeZone)
        }
        if sameNight.count == 1 { return sameNight.first }
        let exact = sameNight.filter { sameEvent(ticketTitle, ticketStart, $0.title, $0.startDate) }
        return exact.count == 1 ? exact.first : nil
    }
}

/// The shows a held ticket already covers, published by `TicketStore` to
/// `GoingStore` so exactly one reminder fires per show — the ticket's, because
/// tapping it opens the QR at the door. Carrying the raw ticket facts (rather
/// than a resolved set of show ids) means a show hearted *after* the ticket is
/// still recognised, without either store watching the other's list.
struct ReminderCoverage: Equatable {
    /// Shows joined by id — stamped at in-app reserve time.
    var showIDs: Set<String> = []
    /// Tickets carrying no id join (reserved on ucbtheatre.com, or restored
    /// from iCloud before the join existed): matched by title + start.
    var events: [Event] = []

    struct Event: Equatable {
        let title: String
        let start: Date
    }

    /// Does a ticket already own this show's reminder?
    func covers(showID: String, title: String, start: Date?) -> Bool {
        if showIDs.contains(showID) { return true }
        return events.contains { ReminderPlan.sameEvent($0.title, $0.start, title, start) }
    }
}
