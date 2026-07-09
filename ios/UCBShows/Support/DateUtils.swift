import Foundation

extension TimeZone {
    /// The venue timezone. Shows are physically in New York; the feed's start
    /// values are timezone-naive local times, so we anchor them here.
    static let newYork = TimeZone(identifier: "America/New_York") ?? .current
}

extension Calendar {
    /// Gregorian calendar fixed to NY time for stable day bucketing.
    static let nyCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .newYork
        return c
    }()
}

/// Parsing/formatting helpers for the feed's date strings, all in NY time.
enum DateUtils {
    /// Parses either `yyyy-MM-dd'T'HH:mm:ss` (timed) or `yyyy-MM-dd` (date-only),
    /// interpreting the value in America/New_York.
    static func parse(_ value: String) -> Date? {
        if value.count == 10 {
            return dateOnlyFormatter.date(from: value)
        }
        return dateTimeFormatter.date(from: value) ?? dateOnlyFormatter.date(from: String(value.prefix(10)))
    }

    static func dayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// Parses the feed's `generated_at` ISO8601 timestamp, e.g.
    /// "2026-06-22T16:08:31.696524+00:00". Python's `isoformat()` emits 6-digit
    /// microseconds, which `ISO8601DateFormatter` rejects (it only accepts 3), so
    /// we strip the fractional component and retry.
    static func parseTimestamp(_ value: String) -> Date? {
        if let date = isoWithFraction.date(from: value) { return date }
        if let date = isoPlain.date(from: value) { return date }
        let stripped = value.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoPlain.date(from: stripped)
    }

    /// "Updated 2h ago" style label for a timestamp.
    static func relativeUpdated(_ date: Date, now: Date = Date()) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return "Updated " + fmt.localizedString(for: date, relativeTo: now)
    }

    /// Section header for a day, e.g. "Today", "Tomorrow", or "Friday, June 26".
    /// Day grouping is venue-local-correct (parse + format share a timezone), but
    /// the relative Today/Tomorrow labels are anchored to NY time — an accepted
    /// simplification that can only differ for LA/Chicago shows within a few hours
    /// of midnight.
    static func sectionTitle(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.nyCalendar
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return weekdayLongFormatter.string(from: date)
    }

    /// e.g. "Jun 26" — compact secondary label.
    static func compactDate(_ date: Date) -> String {
        compactFormatter.string(from: date)
    }

    // MARK: Formatters (cached; each pinned to NY time)

    private static let dateTimeFormatter: DateFormatter = fixed("yyyy-MM-dd'T'HH:mm:ss")
    private static let dateOnlyFormatter: DateFormatter = fixed("yyyy-MM-dd")
    private static let dayKeyFormatter: DateFormatter = fixed("yyyy-MM-dd")
    private static let weekdayLongFormatter: DateFormatter = fixed("EEEE, MMMM d")
    private static let compactFormatter: DateFormatter = fixed("MMM d")

    private static func fixed(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .newYork
        f.dateFormat = format
        return f
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
