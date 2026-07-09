import SwiftUI

/// A poster that fills its frame, with a material shimmer while loading and a
/// first-class `GeneratedCover` fallback when the image is missing or fails —
/// never a broken-image gap. The caller sizes and clips it.
struct PosterImage: View {
    let show: Show
    var body: some View {
        if let url = show.imageURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .empty:
                    // Plain placeholder — a spinner per thumbnail is visual noise
                    // during fast scrolls.
                    Rectangle().fill(.quaternary)
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    GeneratedCover(show: show)
                @unknown default:
                    GeneratedCover(show: show)
                }
            }
        } else {
            GeneratedCover(show: show)
        }
    }
}

/// A typographic 2:1 cover seeded deterministically from the title, with a large
/// comedy-type SF Symbol. Used whenever a poster URL is absent or fails.
struct GeneratedCover: View {
    let show: Show
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: show.seedHue, saturation: 0.50, brightness: 0.55),
                    Color(hue: (show.seedHue + 0.08).truncatingRemainder(dividingBy: 1.0),
                          saturation: 0.62, brightness: 0.34),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: Theme.symbol(forType: show.primaryType))
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(radius: 6, y: 2)
                .accessibilityHidden(true)
        }
    }
}
