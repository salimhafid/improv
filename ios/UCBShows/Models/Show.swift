import Foundation

/// Top-level payload returned by the `/shows.json` endpoint.
struct ShowsPayload: Decodable {
    let generatedAt: String?
    let sourceURL: String?
    let count: Int?
    let sources: [SourceInfo]?
    let shows: [Show]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case sourceURL = "source_url"
        case count
        case sources
        case shows
    }
}

/// A single upcoming UCB show. Decoding is defensive: the scraper can emit
/// `null`/empty for `start`, `end`, `image`, or `post_id`, so those are optional
/// and never abort decoding.
struct Show: Decodable, Identifiable, Hashable {
    let postID: Int?
    let title: String
    let urlString: String?
    let slug: String?
    let dateRaw: String
    let start: String?
    let end: String?
    let hasTime: Bool
    let venue: String
    let venues: [String]
    let isLivestream: Bool
    let comedyTypes: [String]
    let imageString: String?
    let excerpt: String
    /// Full plain-text description scraped from the show's detail page / feed.
    /// Empty when the source provides only a short excerpt.
    let fullDescription: String
    /// Cast / lineup line (e.g. "Featuring: …"), best-effort and source-dependent.
    let cast: String
    let isFree: Bool
    let source: String
    let org: String
    let city: String

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case title
        case urlString = "url"
        case slug
        case dateRaw = "date_raw"
        case start
        case end
        case hasTime = "has_time"
        case venue
        case venues
        case isLivestream = "is_livestream"
        case comedyTypes = "comedy_types"
        case imageString = "image"
        case excerpt
        case fullDescription = "description"
        case cast
        case isFree = "is_free"
        case source
        case org
        case city
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postID = try c.decodeIfPresent(Int.self, forKey: .postID)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled show"
        urlString = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .urlString))
        slug = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .slug))
        dateRaw = (try c.decodeIfPresent(String.self, forKey: .dateRaw)) ?? ""
        start = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .start))
        end = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .end))
        hasTime = (try c.decodeIfPresent(Bool.self, forKey: .hasTime)) ?? false
        venue = (try c.decodeIfPresent(String.self, forKey: .venue)) ?? ""
        venues = (try c.decodeIfPresent([String].self, forKey: .venues)) ?? []
        isLivestream = (try c.decodeIfPresent(Bool.self, forKey: .isLivestream)) ?? false
        comedyTypes = (try c.decodeIfPresent([String].self, forKey: .comedyTypes)) ?? []
        imageString = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .imageString))
        excerpt = (try c.decodeIfPresent(String.self, forKey: .excerpt)) ?? ""
        fullDescription = (try c.decodeIfPresent(String.self, forKey: .fullDescription)) ?? ""
        cast = (try c.decodeIfPresent(String.self, forKey: .cast)) ?? ""
        isFree = (try c.decodeIfPresent(Bool.self, forKey: .isFree)) ?? false
        source = (try c.decodeIfPresent(String.self, forKey: .source)) ?? "ucb_ny"
        org = (try c.decodeIfPresent(String.self, forKey: .org)) ?? "UCB"
        city = (try c.decodeIfPresent(String.self, forKey: .city)) ?? "New York"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - Stable identity & derived display values

extension Show {
    /// Stable identity for diffing/`Identifiable`. Source-prefixed so ids are
    /// unique across sources (e.g. Magnet's numeric /show/ ids vs Annoyance's
    /// numeric ThunderTix ids). Falls back through slug → url → post id → title.
    var id: String {
        let raw = slug ?? urlString ?? postID.map(String.init) ?? title
        return source.isEmpty ? raw : "\(source)/\(raw)"
    }

    var url: URL? {
        guard let urlString, let u = URL(string: urlString),
              u.scheme == "http" || u.scheme == "https" else { return nil }
        return u
    }

    var imageURL: URL? {
        guard let imageString, let u = URL(string: imageString),
              u.scheme == "http" || u.scheme == "https" else { return nil }
        return u
    }

    /// Event start as a `Date`, interpreting the timezone-naive feed value in the
    /// venue's timezone (America/New_York) so day-grouping is stable regardless of
    /// the device's timezone. Returns nil if unparseable.
    var startDate: Date? {
        guard let start else { return nil }
        return DateUtils.parse(start)
    }

    /// Multi-day festival end date (date-only), if any.
    var endDate: Date? {
        guard let end else { return nil }
        return DateUtils.parse(end)
    }

    var isMultiDay: Bool {
        guard let endDate, let startDate else { return false }
        return !Calendar.nyCalendar.isDate(endDate, inSameDayAs: startDate)
    }

    /// `yyyy-MM-dd` bucket key in NY time for grouping; "tba" when undated.
    var dayKey: String {
        guard let startDate else { return "tba" }
        return DateUtils.dayKey(startDate)
    }

    /// Short time shown on cards, e.g. "7:00 PM". Multi-day → "Multiple days",
    /// undated/timeless → "Time TBA".
    var timeLabel: String {
        if let t = Self.extractTime(from: dateRaw) { return t }
        if isMultiDay { return "Multiple days" }
        return hasTime ? "Time TBA" : "All day"
    }

    private static func extractTime(from raw: String) -> String? {
        guard let range = raw.range(of: #"\d{1,2}:\d{2}\s*[AaPp][Mm]"#, options: .regularExpression)
        else { return nil }
        return raw[range].uppercased().replacingOccurrences(of: "  ", with: " ")
    }

    var primaryType: String? { comedyTypes.first }

    /// A "Featuring:/Cast:/Lineup:" label, used to pull the lineup out of the
    /// description into its own section.
    private static let castLabel = #"(?:featuring|cast|line\s*-?up)\s*:\s*"#

    /// Splits the detail copy into the body blurb and the cast list, pulling a
    /// trailing "Featuring: …" clause out of the description so the lineup renders
    /// as a distinct Cast section instead of trailing the blurb. Prefers the
    /// separately-scraped `cast` field for the names when present.
    private var detailParts: (body: String, cast: String) {
        let full = fullDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = full.isEmpty ? excerpt : full
        let field = Self.stripCastLabel(cast)
        if let r = source.range(of: Self.castLabel,
                                options: [.regularExpression, .caseInsensitive]) {
            let body = String(source[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let inline = String(source[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (body, field.isEmpty ? inline : field)
        }
        return (source, field)
    }

    /// Body copy for the detail page — the description with any "Featuring: …"
    /// lineup removed (it's shown separately). Falls back to the excerpt.
    var detailText: String { detailParts.body }

    /// The lineup for the dedicated Cast section. Empty when unknown.
    var castLine: String { detailParts.cast }

    var hasCast: Bool { !detailParts.cast.isEmpty }

    private static func stripCastLabel(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "^" + castLabel,
                           options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short source label for card/detail badges, e.g. "UCB · NYC".
    var sourceLabel: String {
        let cityShort = City(rawValue: city)?.short ?? city
        return cityShort.isEmpty ? org : "\(org) · \(cityShort)"
    }
}
