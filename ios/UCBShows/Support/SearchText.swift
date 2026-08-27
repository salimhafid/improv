import Foundation

/// Search normalization + matching, shared by `ShowsStore` and `ClassesStore`.
/// Both tabs search the same way, so the query folding and the substring scan
/// live in one place rather than one store reaching into the other.
enum SearchText {
    /// Fold + trim + lowercase, to match the `searchHay` each model builds at
    /// decode time. Hoisted out of the filters so a memo key and the match it
    /// guards can share one normalization.
    static func normalized(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Plain substring scan over pre-folded UTF-8. Same predicate as
    /// `searchHay.contains(query)` — both sides are already diacritic-folded
    /// and lowercased — without `String.contains`'s Unicode
    /// canonical-equivalence machinery, which has no early exit and made a
    /// zero-hit query the *slowest* one.
    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard hay.count >= needle.count else { return false }
        let first = needle[0]
        let limit = hay.count - needle.count
        var i = 0
        while i <= limit {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
