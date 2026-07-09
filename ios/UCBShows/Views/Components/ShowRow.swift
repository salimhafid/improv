import SwiftUI

/// The single reusable list unit: poster thumbnail + title + time·venue, with
/// trailing state symbols for livestream / free.
struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(show: show)
                .frame(width: 92, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                        .strokeBorder(.white.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(show.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(show.sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                if show.isLivestream {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                if show.isFree {
                    Image(systemName: "tag")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var secondaryLine: String {
        let venue = show.shortVenue
        return venue.isEmpty ? show.timeLabel : "\(show.timeLabel) · \(venue)"
    }

    private var accessibilityText: String {
        var parts = [show.title, show.timeLabel]
        if !show.shortVenue.isEmpty { parts.append(show.shortVenue) }
        if show.isLivestream { parts.append("Livestream available") }
        if show.isFree { parts.append("Free") }
        return parts.joined(separator: ", ")
    }
}
