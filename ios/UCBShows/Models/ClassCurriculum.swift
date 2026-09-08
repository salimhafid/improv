import Foundation

/// Numbered core courses shared by class browsing and the watcher's category
/// contract. Match course names, never prerequisites or description text.
enum ClassCurriculum: String, CaseIterable {
    case improvCore = "improv_core"
    case sketchCore = "sketch_core"

    var title: String {
        switch self {
        case .improvCore: return "Improv Core"
        case .sketchCore: return "Sketch Core"
        }
    }

    struct Course: Equatable {
        let curriculum: ClassCurriculum
        let rank: Int
    }

    private static let labels = try! NSRegularExpression(
        pattern: #"^\s*(?:\[[^\]]*\]\s*)*(?:online\s+)?"#, options: .caseInsensitive)
    private static let coursePrefix = try! NSRegularExpression(
        pattern: #"^(improv|sketch)(?:\s*:\s*|\s+)(?:level\s+)?([0-9]+)\b"#,
        options: .caseInsensitive)
    private static let numberedPrefix = try! NSRegularExpression(
        pattern: #"^(improv|sketch)(?:\s*:\s*|\s+)(?:level\s+)?[0-9]"#,
        options: .caseInsensitive)
    private static let nonCorePrefix = try! NSRegularExpression(
        pattern: #"^(?:musical|advanced)\b"#, options: .caseInsensitive)

    private static func normalized(_ value: String) -> String {
        let unlabelled = labels.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        return unlabelled.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// UCB campuses teach Improv 101–401 / Sketch 101–301; BCC teaches
    /// Improv 1–4 / Sketch 1–2. A numbered drop-in or intensive stays with its
    /// course. A renamed title may use the canonical level, unless its title
    /// explicitly names a different numbered or musical/advanced course.
    static func course(source: String, title: String, level: String = "") -> Course? {
        let isUCB = ["ucb_ny", "ucb_la", "ucb_online"].contains(source)
        guard isUCB || source == "brooklyn_cc" else { return nil }
        for value in [title, level] {
            let text = normalized(value)
            let range = NSRange(text.startIndex..., in: text)
            if nonCorePrefix.firstMatch(in: text, range: range) != nil { return nil }
            guard let match = coursePrefix.firstMatch(in: text, range: range),
                  let disciplineRange = Range(match.range(at: 1), in: text),
                  let numberRange = Range(match.range(at: 2), in: text) else {
                // "101A" is an explicit different course, not a renamed title
                // whose stale level should turn it back into 101.
                if numberedPrefix.firstMatch(in: text, range: range) != nil { return nil }
                continue
            }
            let curriculum: ClassCurriculum = text[disciplineRange].lowercased() == "improv"
                ? .improvCore : .sketchCore
            let numbers: [String]
            switch (isUCB, curriculum) {
            case (true, .improvCore): numbers = ["101", "201", "301", "401"]
            case (true, .sketchCore): numbers = ["101", "201", "301"]
            case (false, .improvCore): numbers = ["1", "2", "3", "4"]
            case (false, .sketchCore): numbers = ["1", "2"]
            }
            guard let rank = numbers.firstIndex(of: String(text[numberRange])) else { return nil }
            return Course(curriculum: curriculum, rank: rank)
        }
        return nil
    }
}
