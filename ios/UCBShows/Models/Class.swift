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
/// missing, empty or wrong-typed in the feed, so all are optional-with-default
/// and never abort decoding.
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
    /// UTF-8 bytes of `searchHay`. `String.contains` does Unicode
    /// canonical-equivalence matching with no early exit, so a *miss* scans the
    /// whole ~700-character haystack — measured at 3.4 ms per keystroke across
    /// one city's classes, and getting worse the more the user types. Both
    /// sides are already folded and lowercased, so a byte compare is the same
    /// predicate ~30x cheaper.
    let searchBytes: [UInt8]
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
        // `try?` throughout: a wrong-typed value drops that field to its
        // default, never the whole row (the payload's `Lossy` would discard it).
        rawID = (try? c.decodeIfPresent(String.self, forKey: .rawID)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled class"
        urlString = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .urlString))
        instructor = (try? c.decodeIfPresent(String.self, forKey: .instructor)) ?? ""
        schedule = (try? c.decodeIfPresent(String.self, forKey: .schedule)) ?? ""
        start = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .start))
        price = (try? c.decodeIfPresent(String.self, forKey: .price)) ?? ""
        level = (try? c.decodeIfPresent(String.self, forKey: .level)) ?? ""
        imageString = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .imageString))
        classDescription = (try? c.decodeIfPresent(String.self, forKey: .classDescription)) ?? ""
        isFull = (try? c.decodeIfPresent(Bool.self, forKey: .isFull)) ?? false
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        org = (try? c.decodeIfPresent(String.self, forKey: .org)) ?? ""
        city = (try? c.decodeIfPresent(String.self, forKey: .city)) ?? ""

        let tz = City(rawValue: city)?.timeZone ?? .newYork
        startDate = start.flatMap { DateUtils.parse($0, in: tz) }
        searchHay = ([title, instructor, level, org, classDescription]
            .joined(separator: " "))
            .folding(options: .diacriticInsensitive, locale: .current).lowercased()
        searchBytes = Array(searchHay.utf8)
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
        // Whole words only: as a substring test "jam" matched "James" and filed
        // iO's Level 4/5 core classes under Workshops. Hyphens split like
        // spaces, so "stand-up" / "stand up" / "drop-in" are one keyword each;
        // a keyword ending in "*" is a stem ("clowning", "storytellers").
        let words = (level + " " + title).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let rules: [(String, [String])] = [
            ("Teens & Youth", ["teen", "youth", "kids", "young"]),
            ("Musical Improv", ["musical"]),
            ("Sketch & Writing", ["sketch", "writing", "writer"]),
            ("Acting & Character", ["character", "acting", "on camera"]),
            ("Stand-Up", ["stand up", "standup"]),
            ("Clowning", ["clown*"]),
            ("Storytelling", ["storytell*"]),
            ("Workshops & Drop-Ins", ["workshop", "drop in", "jam", "elective", "intensive"]),
        ]
        for (bucket, keywords) in rules where keywords.contains(where: { hasKeyword(words, $0) }) {
            return bucket
        }
        return "Improv"
    }

    /// Does the word list contain the keyword as consecutive whole words? A
    /// plural "s" still counts; a trailing "*" matches any word the stem begins.
    private static func hasKeyword(_ words: [String], _ keyword: String) -> Bool {
        let parts = keyword.split(separator: " ").map(String.init)
        guard !parts.isEmpty, words.count >= parts.count else { return false }
        return (0...(words.count - parts.count)).contains { offset in
            zip(parts, words[offset...]).allSatisfy { part, word in
                if part.hasSuffix("*") { return word.hasPrefix(part.dropLast()) }
                return word == part || word == part + "s"
            }
        }
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

    /// Each teacher named in `instructor`, so the class page can link them
    /// one by one. UCB joins Arlo's presenters with ", "; other schools write
    /// "A & B" or "A and B". A trailing "Jr."/"Sr."/roman numeral after a
    /// comma stays with the name before it.
    var instructorNames: [String] { Self.splitInstructors(instructor) }

    static func splitInstructors(_ raw: String) -> [String] {
        let parts = raw
            .replacingOccurrences(of: #"\s*&\s*|\s+and\s+"#, with: ",",
                                  options: [.regularExpression, .caseInsensitive])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var names: [String] = []
        for part in parts {
            let suffix = part.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let last = names.last, ["jr", "sr", "ii", "iii", "iv"].contains(suffix) {
                names[names.count - 1] = "\(last), \(part)"
            } else {
                names.append(part)
            }
        }
        return names
    }

    /// "Teacher TBD", "TBA", "Staff": a stand-in, not a person to look up.
    /// "Staff" only as the whole name, so a teacher surnamed Staff still links.
    static func isPlaceholderInstructor(_ name: String) -> Bool {
        if name.range(of: #"\b(tbd|tba|tbc|to be (announced|determined|confirmed))\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let whole = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["staff", "ucb staff", "teacher", "instructor", "various", "various instructors"]
            .contains(whole)
    }

    /// Google search for a teacher with no UCB bio: "<name> + <theater>",
    /// e.g. "Shannon O'Neill + UCB". The "+" is percent-encoded so Google
    /// shows the query exactly as written rather than reading it as a space.
    static func instructorSearchURL(name: String, theater: String) -> URL? {
        let query = [name, theater].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " + ")
        guard !query.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}
