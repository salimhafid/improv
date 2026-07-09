import Foundation

/// Top-level payload returned by the `/classes.json` endpoint.
struct ClassesPayload: Decodable {
    let generatedAt: String?
    let count: Int?
    let sources: [SourceInfo]?
    let classes: [ClassItem]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case count
        case sources
        case classes
    }
}

/// A single class / workshop offering. Decoding is defensive: any field can be
/// missing or empty in the feed, so all are optional-with-default and never abort
/// decoding.
struct ClassItem: Decodable, Identifiable, Hashable {
    let rawID: String
    let title: String
    let urlString: String?
    let instructor: String
    let schedule: String
    let start: String?
    let price: String
    let level: String
    let imageString: String?
    let classDescription: String
    let isFull: Bool
    let source: String
    let org: String
    let city: String

    enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case title
        case urlString = "url"
        case instructor
        case schedule
        case start
        case price
        case level
        case imageString = "image"
        case classDescription = "description"
        case isFull = "is_full"
        case source
        case org
        case city
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawID = (try c.decodeIfPresent(String.self, forKey: .rawID)) ?? ""
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled class"
        urlString = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .urlString))
        instructor = (try c.decodeIfPresent(String.self, forKey: .instructor)) ?? ""
        schedule = (try c.decodeIfPresent(String.self, forKey: .schedule)) ?? ""
        start = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .start))
        price = (try c.decodeIfPresent(String.self, forKey: .price)) ?? ""
        level = (try c.decodeIfPresent(String.self, forKey: .level)) ?? ""
        imageString = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .imageString))
        classDescription = (try c.decodeIfPresent(String.self, forKey: .classDescription)) ?? ""
        isFull = (try c.decodeIfPresent(Bool.self, forKey: .isFull)) ?? false
        source = (try c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        org = (try c.decodeIfPresent(String.self, forKey: .org)) ?? ""
        city = (try c.decodeIfPresent(String.self, forKey: .city)) ?? ""
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - Stable identity & derived display values

extension ClassItem {
    /// Stable identity, source-prefixed so ids are unique across theaters (Arlo
    /// numeric ids, WGIS workshop ids, Crowdwork slugs can collide otherwise).
    var id: String {
        let raw = rawID.isEmpty ? (urlString ?? "\(source)-\(title)") : rawID
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

    /// Start as a `Date`, interpreting the timezone-naive feed value in NY time
    /// (matches the shows feed convention). Nil if undated/unparseable.
    var startDate: Date? {
        guard let start else { return nil }
        return DateUtils.parse(start)
    }

    /// Short theater label for badges, e.g. "WGIS · LA".
    var sourceLabel: String {
        let cityShort = City(rawValue: city)?.short ?? city
        return cityShort.isEmpty ? org : "\(org) · \(cityShort)"
    }

    /// Secondary line for a row: instructor and/or schedule, whichever exist.
    var subtitleLine: String {
        [instructor, schedule].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
