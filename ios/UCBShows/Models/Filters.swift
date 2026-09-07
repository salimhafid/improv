import Foundation

/// User-selected filters applied to the show list. Value type so it's trivially
/// `Equatable` and cheap to copy.
struct Filters: Equatable, Codable {
    enum DateWindow: String, CaseIterable, Identifiable, Codable {
        case all, week, weekend, twoWeeks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:      return "Any date"
            case .week:     return "This week"
            case .weekend:  return "This weekend"
            case .twoWeeks: return "Next 2 weeks"
            }
        }
    }

    // City + theater are no longer filters — they come from AppState (the
    // theater sidebar). What remains refines within that scope.
    var venue: String? = nil
    var comedyTypes: Set<String> = []
    var livestreamOnly = false
    var freeOnly = false
    var dateWindow: DateWindow = .all

    init() {}

    /// Persisted (UserDefaults, mirrored to every device via iCloud KVS), so
    /// decoding is field-lenient: a key this build doesn't know, or a
    /// `DateWindow` case it no longer has, resets that field alone rather than
    /// throwing the whole saved filter set away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        venue = try? c.decodeIfPresent(String.self, forKey: .venue)
        comedyTypes = (try? c.decodeIfPresent(Set<String>.self, forKey: .comedyTypes)) ?? []
        livestreamOnly = (try? c.decodeIfPresent(Bool.self, forKey: .livestreamOnly)) ?? false
        freeOnly = (try? c.decodeIfPresent(Bool.self, forKey: .freeOnly)) ?? false
        dateWindow = (try? c.decodeIfPresent(DateWindow.self, forKey: .dateWindow)) ?? .all
    }

    enum CodingKeys: String, CodingKey {
        case venue, comedyTypes, livestreamOnly, freeOnly, dateWindow
    }

    var isActive: Bool {
        venue != nil || !comedyTypes.isEmpty
            || livestreamOnly || freeOnly || dateWindow != .all
    }

    var activeCount: Int {
        var n = 0
        if venue != nil { n += 1 }
        n += comedyTypes.count
        if livestreamOnly { n += 1 }
        if freeOnly { n += 1 }
        if dateWindow != .all { n += 1 }
        return n
    }

    mutating func clear() { self = Filters() }
}
