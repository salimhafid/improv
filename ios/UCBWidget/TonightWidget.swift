import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Configuration (theater picker)

/// The theaters the widget can show. Deliberately duplicated from the app's
/// `SourceCatalog` (ids must match the feed's source ids) — the widget target is
/// self-contained so it needs no shared framework or app-group plumbing.
enum TheaterChoice: String, AppEnum {
    case allNewYork, ucbNY, brooklynCC, magnet, wgisNY
    case allLosAngeles, ucbLA, wgisLA
    case allChicago, annoyance, ioChicago

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Theater"
    static let caseDisplayRepresentations: [TheaterChoice: DisplayRepresentation] = [
        .allNewYork: "All New York", .ucbNY: "UCB New York",
        .brooklynCC: "Brooklyn Comedy Collective", .magnet: "Magnet Theater",
        .wgisNY: "WGIS New York",
        .allLosAngeles: "All Los Angeles", .ucbLA: "UCB Los Angeles",
        .wgisLA: "WGIS Los Angeles",
        .allChicago: "All Chicago", .annoyance: "The Annoyance",
        .ioChicago: "iO Theater",
    ]

    /// Feed source id to match, or nil for a whole-city choice.
    var sourceID: String? {
        switch self {
        case .allNewYork, .allLosAngeles, .allChicago: return nil
        case .ucbNY: return "ucb_ny"
        case .brooklynCC: return "brooklyn_cc"
        case .magnet: return "magnet"
        case .wgisNY: return "wgis_ny"
        case .ucbLA: return "ucb_la"
        case .wgisLA: return "wgis_la"
        case .annoyance: return "annoyance"
        case .ioChicago: return "io_chicago"
        }
    }

    /// Feed city value to match.
    var city: String {
        switch self {
        case .allNewYork, .ucbNY, .brooklynCC, .magnet, .wgisNY: return "New York"
        case .allLosAngeles, .ucbLA, .wgisLA: return "Los Angeles"
        case .allChicago, .annoyance, .ioChicago: return "Chicago"
        }
    }

    var timeZone: TimeZone {
        switch city {
        case "Los Angeles": return TimeZone(identifier: "America/Los_Angeles") ?? .current
        case "Chicago":     return TimeZone(identifier: "America/Chicago") ?? .current
        default:            return TimeZone(identifier: "America/New_York") ?? .current
        }
    }

    var shortName: String {
        switch self {
        case .allNewYork: return "New York"
        case .ucbNY, .ucbLA: return "UCB"
        case .brooklynCC: return "BCC"
        case .magnet: return "Magnet"
        case .wgisNY, .wgisLA: return "WGIS"
        case .allLosAngeles: return "Los Angeles"
        case .allChicago: return "Chicago"
        case .annoyance: return "Annoyance"
        case .ioChicago: return "iO"
        }
    }
}

struct TonightConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Tonight"
    static let description = IntentDescription("Tonight's shows at your theater.")

    @Parameter(title: "Theater", default: .ucbNY)
    var theater: TheaterChoice
}

// MARK: - Feed (trimmed decode of shows.json)

private struct WidgetFeed: Decodable {
    let shows: [WidgetFeedShow]
}

private struct WidgetFeedShow: Decodable {
    let title: String?
    let start: String?
    let venue: String?
    let source: String?
    let city: String?
}

/// One row in the widget.
struct TonightShow: Identifiable {
    let id: Int
    let time: String     // "7:00 PM"
    let title: String
    let sortKey: Date
}

enum TonightLoader {
    static let feedURL = URL(string: "https://ucb-ny-shows-315881650478.us-central1.run.app/shows.json")!

    /// Today's shows (venue-local day, from now onward) for the chosen theater.
    static func load(for choice: TheaterChoice) async -> [TonightShow] {
        guard let (data, _) = try? await URLSession.shared.data(from: feedURL),
              let feed = try? JSONDecoder().decode(WidgetFeed.self, from: data) else { return [] }

        let tz = choice.timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = tz
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = tz
        timeFmt.dateFormat = "h:mm a"

        let now = Date()
        return feed.shows.enumerated().compactMap { index, show -> TonightShow? in
            guard show.city == choice.city else { return nil }
            if let source = choice.sourceID, show.source != source { return nil }
            guard let raw = show.start, let start = parse.date(from: raw),
                  cal.isDate(start, inSameDayAs: now),
                  start > now.addingTimeInterval(-45 * 60)   // keep just-started shows
            else { return nil }
            return TonightShow(id: index,
                               time: timeFmt.string(from: start),
                               title: show.title ?? "Untitled show",
                               sortKey: start)
        }
        .sorted { $0.sortKey < $1.sortKey }
    }
}

// MARK: - Timeline

struct TonightEntry: TimelineEntry {
    let date: Date
    let theater: String
    let shows: [TonightShow]
}

struct TonightProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TonightEntry {
        TonightEntry(date: .now, theater: "UCB", shows: [
            TonightShow(id: 0, time: "7:00 PM", title: "Harold Night", sortKey: .now),
            TonightShow(id: 1, time: "9:30 PM", title: "Cagematch", sortKey: .now),
        ])
    }

    func snapshot(for configuration: TonightConfigIntent, in context: Context) async -> TonightEntry {
        TonightEntry(date: .now, theater: configuration.theater.shortName,
                     shows: await TonightLoader.load(for: configuration.theater))
    }

    func timeline(for configuration: TonightConfigIntent, in context: Context) async -> Timeline<TonightEntry> {
        let entry = TonightEntry(date: .now, theater: configuration.theater.shortName,
                                 shows: await TonightLoader.load(for: configuration.theater))
        // Refresh every couple of hours; the backend itself scrapes on a schedule.
        let next = Date().addingTimeInterval(2 * 3600)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

// MARK: - Views

struct TonightWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TonightEntry

    private let accent = Color(red: 0.94, green: 0.42, blue: 0.36)   // app coral

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.shows.isEmpty {
                Spacer()
                Text("No shows tonight")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                rows
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "theatermasks.fill")
            Text("Tonight · \(entry.theater)")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(accent)
    }

    private var maxRows: Int { family == .systemSmall ? 2 : 3 }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(entry.shows.prefix(maxRows)) { show in
                if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(show.time)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(show.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(show.time)
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(show.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                }
            }
            if entry.shows.count > maxRows {
                Text("+\(entry.shows.count - maxRows) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct TonightWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TonightWidget",
                               intent: TonightConfigIntent.self,
                               provider: TonightProvider()) { entry in
            TonightWidgetView(entry: entry)
        }
        .configurationDisplayName("Tonight")
        .description("Tonight's shows at your theater.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
