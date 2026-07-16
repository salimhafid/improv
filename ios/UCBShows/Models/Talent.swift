import Foundation

/// Top-level payload returned by the `/talent.json` endpoint.
struct TalentPayload: Decodable {
    let generatedAt: String?
    let count: Int?
    let people: [TalentPerson]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case count
        case people
    }
}

/// One person in the UCB talent directory (NY performers / DCM / teachers).
/// Decoding is defensive, matching the show/class models.
struct TalentPerson: Decodable, Identifiable, Hashable {
    let name: String
    let slug: String
    let urlString: String?
    let imageString: String?
    let groups: [String]

    enum CodingKeys: String, CodingKey {
        case name, slug
        case urlString = "url"
        case imageString = "image"
        case groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        slug = (try c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        imageString = try c.decodeIfPresent(String.self, forKey: .imageString)
        groups = (try c.decodeIfPresent([String].self, forKey: .groups)) ?? []
    }

    var id: String { slug }

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

    /// Display labels for the person's groups, in a stable order.
    var groupLabels: [String] {
        var out: [String] = []
        if groups.contains("ny") { out.append("NY Cast") }
        if groups.contains("dcm") { out.append("DCM") }
        if groups.contains("teachers") { out.append("Teacher") }
        return out
    }

    /// Normalized key for matching cast-line names to directory entries:
    /// lowercased, diacritic-folded, parentheticals ("(AB)") and punctuation
    /// dropped, whitespace collapsed.
    static func nameKey(_ raw: String) -> String {
        var t = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        t = t.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }
}
