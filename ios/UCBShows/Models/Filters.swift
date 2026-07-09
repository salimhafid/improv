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

    // City + theater are no longer filters — they come from AppState (the Setup
    // city picker and the theater sidebar). What remains refines within that scope.
    var venue: String? = nil
    var comedyTypes: Set<String> = []
    var livestreamOnly = false
    var freeOnly = false
    var dateWindow: DateWindow = .all

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

/// Filters applied to the classes list within the selected city + theater scope:
/// level/track and an open-only toggle. (City + theater come from AppState.)
struct ClassFilters: Equatable, Codable {
    var level: String? = nil
    var openOnly = false         // hide classes marked full

    var isActive: Bool {
        level != nil || openOnly
    }

    var activeCount: Int {
        var n = 0
        if level != nil { n += 1 }
        if openOnly { n += 1 }
        return n
    }

    mutating func clear() { self = ClassFilters() }
}
