import SwiftUI

/// A theater's favicon (bundled in Assets.xcassets as `theater_<sourceID>`,
/// fetched once from each theater's site — they don't change), shown as a small
/// rounded tile. Falls back to the generic masks symbol for ids without one.
struct TheaterIcon: View {
    let id: String
    var size: CGFloat = 28

    var body: some View {
        if UIImage(named: "theater_\(id)") != nil {
            Image("theater_\(id)")
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
        } else {
            Image(systemName: "theatermasks.fill")
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
