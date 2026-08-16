import Foundation

/// The cities the app spans — a grouping label for theaters (sidebar sections)
/// and the unit the Classes tab browses in. Never picked directly: it's always
/// inferred from the selected theaters. Case order is the display order.
enum City: String, CaseIterable, Identifiable, Codable {
    case newYork = "New York"
    case chicago = "Chicago"
    case losAngeles = "Los Angeles"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .newYork:    return "building.2.fill"
        case .losAngeles: return "sun.max.fill"
        case .chicago:    return "wind"
        }
    }

    var short: String {
        switch self {
        case .newYork:    return "NYC"
        case .losAngeles: return "LA"
        case .chicago:    return "CHI"
        }
    }

    /// The city's local timezone. The feed's start values are timezone-naive
    /// venue-local times, so each show is parsed and day-bucketed in its own
    /// city's zone (and "Today"/date windows compare against that zone's now).
    var timeZone: TimeZone {
        switch self {
        case .newYork:    return TimeZone(identifier: "America/New_York") ?? .current
        case .losAngeles: return TimeZone(identifier: "America/Los_Angeles") ?? .current
        case .chicago:    return TimeZone(identifier: "America/Chicago") ?? .current
        }
    }
}

/// A source the app knows how to show, listed in the sidebar even before the feed
/// loads or when the source is currently unavailable.
struct SourceCatalogEntry: Identifiable, Hashable {
    let id: String        // matches the feed's source id
    let name: String      // display name, e.g. "Brooklyn Comedy Collective"
    let blurb: String     // neighborhood / subtitle
    let city: City
    /// False for class-only schools (no shows feed) — they're hidden from the
    /// theater sidebar, but their classes still show up under their city.
    var hasShows = true
}

/// Per-source availability + counts from the feed's `sources` array. Decoded
/// defensively like every other feed model — one malformed row must not abort
/// the payload.
struct SourceInfo: Decodable, Identifiable, Hashable {
    let id: String
    let org: String
    let city: String
    let count: Int
    let ok: Bool
    let error: String?

    enum CodingKeys: String, CodingKey { case id, org, city, count, ok, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        org = (try c.decodeIfPresent(String.self, forKey: .org)) ?? ""
        city = (try c.decodeIfPresent(String.self, forKey: .city)) ?? ""
        count = (try c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        ok = (try c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Element-lossy array decoding: a single undecodable element (schema drift in
/// one show/class/person) drops that element instead of aborting the whole
/// payload — the "never abort decoding" intent, applied to arrays too.
struct Lossy<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct AnyDecodable: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else {
                _ = try? container.decode(AnyDecodable.self)  // skip the bad element
            }
        }
        elements = out
    }
}

/// The supported sources (the 4 wired venues + iO, which is currently unavailable).
enum SourceCatalog {
    static let all: [SourceCatalogEntry] = [
        .init(id: "ucb_ny", name: "UCB New York", blurb: "Upright Citizens Brigade", city: .newYork),
        .init(id: "brooklyn_cc", name: "Brooklyn Comedy Collective", blurb: "Williamsburg, Brooklyn", city: .newYork),
        .init(id: "magnet", name: "Magnet Theater", blurb: "Chelsea, Manhattan", city: .newYork),
        .init(id: "wgis_ny", name: "WGIS New York", blurb: "World’s Greatest Improv School", city: .newYork,
              hasShows: false),   // classes only — no shows feed
        .init(id: "ucb_la", name: "UCB Los Angeles", blurb: "Upright Citizens Brigade", city: .losAngeles),
        .init(id: "wgis_la", name: "WGIS Los Angeles", blurb: "World’s Greatest Improv School", city: .losAngeles),
        .init(id: "annoyance", name: "The Annoyance", blurb: "Lakeview, Chicago", city: .chicago),
        .init(id: "io_chicago", name: "iO Theater", blurb: "Chicago", city: .chicago),
        .init(id: "second_city", name: "The Second City", blurb: "Old Town, Chicago", city: .chicago),
        .init(id: "logan_square", name: "Logan Square Improv", blurb: "Logan Square, Chicago", city: .chicago),
        .init(id: "playground", name: "The Playground Theater", blurb: "Lakeview, Chicago", city: .chicago),
    ]

    /// Theaters selectable in the sidebar (shows feed exists).
    static let showIDs = Set(all.filter(\.hasShows).map(\.id))

    /// Catalog grouped by city, in city order, skipping empty cities. Only
    /// theaters with shows — this feeds the sidebar, which scopes the shows
    /// feed.
    static var byCity: [(city: City, entries: [SourceCatalogEntry])] {
        City.allCases.compactMap { city in
            let entries = all.filter { $0.city == city && $0.hasShows }
            return entries.isEmpty ? nil : (city, entries)
        }
    }

    static func entry(_ id: String) -> SourceCatalogEntry? { all.first { $0.id == id } }

    /// Class sources visible for a theater selection: **every** school in the
    /// selection's cities, not just the picked theaters. Classes are browsed
    /// city-wide — picking UCB New York surfaces Magnet, BCC and WGIS NY too —
    /// while the shows feed stays scoped to the picked theaters.
    ///
    /// The empty set keeps its "no scoping" meaning, and unknown ids stay in
    /// the scope alone: without the union an unrecognized id would yield ∅,
    /// which downstream reads as *every* class in every city.
    static func classScope(for theaters: Set<String>) -> Set<String> {
        guard !theaters.isEmpty else { return [] }
        let cities = Set(theaters.compactMap { entry($0)?.city })
        return Set(all.filter { cities.contains($0.city) }.map(\.id)).union(theaters)
    }
}
