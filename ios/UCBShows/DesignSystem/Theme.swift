import SwiftUI

/// Central design tokens. Color/dark-mode is almost entirely system-driven; the
/// only brand color is a single warm coral accent, plus low-saturation tints for
/// comedy-type chips.
enum Theme {
    /// App accent (defined in the asset catalog with light/dark variants).
    static let accent = Color("AccentColor")

    enum Radius {
        static let thumb: CGFloat = 12
        static let card: CGFloat = 20
        static let chip: CGFloat = 10
    }

    enum Space {
        static let gutter: CGFloat = 16
        static let section: CGFloat = 24
    }

    /// Low-saturation tint per comedy type for at-a-glance scanning.
    static func tint(forType type: String) -> Color {
        switch type.lowercased() {
        case "improv":    return Color(red: 0.18, green: 0.55, blue: 0.55) // teal
        case "sketch":    return Color(red: 0.45, green: 0.38, blue: 0.72) // purple
        case "character": return Color(red: 0.86, green: 0.42, blue: 0.40) // coral
        case "standup", "stand-up", "stand up": return Color(red: 0.80, green: 0.58, blue: 0.20) // amber
        default:          return Color.secondary
        }
    }

    /// SF Symbol per comedy type (used by GeneratedCover and chips).
    static func symbol(forType type: String?) -> String {
        switch (type ?? "").lowercased() {
        case "improv":    return "mic"
        case "sketch":    return "pencil.and.outline"
        case "character": return "person.fill"
        case "standup", "stand-up", "stand up": return "music.mic"
        default:          return "theatermasks.fill"
        }
    }
}

extension Show {
    /// Deterministic hue (0–1) seeded from the title, for GeneratedCover and the
    /// ambient hero/detail gradient. Avoids per-pixel poster sampling entirely.
    var seedHue: Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in title.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Double(hash % 360) / 360.0
    }
}
