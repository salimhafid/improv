import Foundation

/// Top-level payload returned by the `/classes.json` endpoint. Arrays decode
/// element-lossily (see `Lossy`).
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        sources = (try c.decodeIfPresent(Lossy<SourceInfo>.self, forKey: .sources))?.elements
        classes = (try c.decodeIfPresent(Lossy<ClassItem>.self, forKey: .classes))?.elements ?? []
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

    // Derived once at decode time (see Show for why): re-parsing dates and
    // re-folding search text per access made section sorts O(n·parse).
    let startDate: Date?
    /// Pre-folded lowercase haystack for search matching.
    let searchHay: String
    /// Cross-school subject bucket ("Improv", "Sketch & Writing", …) — computed
    /// once at decode; drives the Classes tab's Subject grouping.
    let subject: String

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

        let tz = City(rawValue: city)?.timeZone ?? .newYork
        startDate = start.flatMap { DateUtils.parse($0, in: tz) }
        searchHay = ([title, instructor, level, org, classDescription]
            .joined(separator: " "))
            .folding(options: .diacriticInsensitive, locale: .current).lowercased()
        subject = Self.classifySubject(level: level, title: title)
    }

    /// Keyword classifier over each school's own level/track naming, so one
    /// consistent set of buckets spans every theater. First match wins; the
    /// fallback is Improv — at these schools an unlabeled program (Annoyance
    /// AP1–5, "Harold", iO levels) is an improv program.
    static let subjectOrder: [String] = [
        "Improv", "Musical Improv", "Sketch & Writing", "Acting & Character",
        "Stand-Up", "Clowning", "Storytelling", "Teens & Youth", "Workshops & Drop-Ins",
    ]

    static func classifySubject(level: String, title: String) -> String {
        let hay = (level + " " + title).lowercased()
        let rules: [(String, [String])] = [
            ("Teens & Youth", ["teen", "youth", "kids", "young"]),
            ("Musical Improv", ["musical"]),
            ("Sketch & Writing", ["sketch", "writing", "writer"]),
            ("Acting & Character", ["character", "acting", "on-camera", "on camera"]),
            ("Stand-Up", ["stand-up", "standup", "stand up"]),
            ("Clowning", ["clown"]),
            ("Storytelling", ["storytell"]),
            ("Workshops & Drop-Ins", ["workshop", "drop-in", "drop in", "jam", "elective", "intensive"]),
        ]
        for (bucket, keywords) in rules where keywords.contains(where: hay.contains) {
            return bucket
        }
        return "Improv"
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
