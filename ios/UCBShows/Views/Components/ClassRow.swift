import SwiftUI

/// A single class row: a level-tinted glyph, title + instructor/schedule, theater
/// label, and a trailing price with an optional "Full" badge.
struct ClassRow: View {
    let item: ClassItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                .fill(Theme.accent.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "graduationcap.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if !item.subtitleLine.isEmpty {
                    Text(item.subtitleLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(item.sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if !item.price.isEmpty {
                    Text(item.price)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if item.isFull {
                    Text("Full")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else if item.url != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.title]
        if !item.subtitleLine.isEmpty { parts.append(item.subtitleLine) }
        parts.append(item.sourceLabel)
        if !item.price.isEmpty { parts.append(item.price) }
        if item.isFull { parts.append("Full") }
        return parts.joined(separator: ", ")
    }
}
