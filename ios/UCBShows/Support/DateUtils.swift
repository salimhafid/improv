import Foundation

extension TimeZone {
    /// Fallback venue timezone for feed values whose city is unknown.
    static let newYork = TimeZone(identifier: "America/New_York") ?? .current
}

/// Parsing/formatting helpers for the feed's date strings. The feed emits
/// timezone-naive venue-local times, so every helper takes the venue's timezone
/// (from `City.timeZone`) and parses/formats/buckets in that zone.
enum DateUtils {
    /// Gregorian calendar pinned to a timezone (cached per zone).
    static func calendar(in tz: TimeZone) -> Calendar {
        calendars[tz.identifier] ?? {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = tz
            return c
        }()
    }

    /// Parses either `yyyy-MM-dd'T'HH:mm:ss` (timed) or `yyyy-MM-dd` (date-only),
    /// interpreting the value in the venue's timezone.
    static func parse(_ value: String, in tz: TimeZone) -> Date? {
        if value.count == 10 {
            return formatter(.dateOnly, in: tz).date(from: value)
        }
        return formatter(.dateTime, in: tz).date(from: value)
            ?? formatter(.dateOnly, in: tz).date(from: String(value.prefix(10)))
    }

    /// `yyyy-MM-dd` bucket key in the venue's local day.
    static func dayKey(_ date: Date, in tz: TimeZone) -> String {
        formatter(.dateOnly, in: tz).string(from: date)
    }

    /// Venue-local short time, e.g. "7:00 PM".
    static func timeString(_ date: Date, in tz: TimeZone) -> String {
        formatter(.time, in: tz).string(from: date)
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

    /// Section header for a day, e.g. "Today", "Tomorrow", or "Friday, June 26" —
    /// all reckoned in the venue's timezone, so "Today" flips at the venue's
    /// midnight, not New York's.
    static func sectionTitle(for date: Date, in tz: TimeZone, now: Date = Date()) -> String {
        let cal = calendar(in: tz)
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return formatter(.weekdayLong, in: tz).string(from: date)
    }

    /// e.g. "Jun 26" — compact secondary label.
    static func compactDate(_ date: Date, in tz: TimeZone) -> String {
        formatter(.compact, in: tz).string(from: date)
    }

    // MARK: Formatters (prebuilt per supported timezone)

    private enum Format: String, CaseIterable {
        case dateTime = "yyyy-MM-dd'T'HH:mm:ss"
        case dateOnly = "yyyy-MM-dd"
        case weekdayLong = "EEEE, MMMM d"
        case compact = "MMM d"
        case time = "h:mm a"
    }

    /// One immutable formatter per (format, zone), built once for the supported
    /// city zones; unknown zones get a fresh instance as a safety net.
    private static func formatter(_ format: Format, in tz: TimeZone) -> DateFormatter {
        formatters["\(tz.identifier)|\(format.rawValue)"] ?? make(format, tz)
    }

    private static let supportedZones: [TimeZone] =
        City.allCases.map(\.timeZone) + [.newYork]

    private static let formatters: [String: DateFormatter] = {
        var all: [String: DateFormatter] = [:]
        for tz in supportedZones {
            for format in Format.allCases {
                all["\(tz.identifier)|\(format.rawValue)"] = make(format, tz)
            }
        }
        return all
    }()

    private static let calendars: [String: Calendar] = {
        var all: [String: Calendar] = [:]
        for tz in supportedZones {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = tz
            all[tz.identifier] = c
        }
        return all
    }()

    private static func make(_ format: Format, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format.rawValue
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
