import ImageIO
import SwiftUI

/// Downsampling poster loader. The feed's LazyVStack never recycles rows, so
/// decoding every poster at source resolution (what AsyncImage does) let
/// full-size bitmaps accumulate as the user scrolled. This decodes each poster
/// at its display scale with ImageIO and caches the decoded thumbnail; bytes
/// still come through URLSession.shared → the app's generous URLCache.
enum PosterPipeline {
    private static let decoded = NSCache<NSString, UIImage>()

    static func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let key = "\(url.absoluteString)#\(maxPixel)" as NSString
        if let hit = decoded.object(forKey: key) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cg)
        decoded.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }
}

/// A poster that fills its frame, with a quiet placeholder while loading and a
/// first-class `GeneratedCover` fallback when the image is missing or fails —
/// never a broken-image gap. The caller sizes and clips it. `maxPixel` bounds
/// the decode: the row default comfortably covers 92×58pt thumbs @3x; the
/// detail hero passes a larger budget.
struct PosterImage: View {
    let show: Show
    var maxPixel: Int = 640

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed || show.imageURL == nil {
                GeneratedCover(show: show)
            } else {
                // Plain placeholder — a spinner per thumbnail is visual noise
                // during fast scrolls.
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: show.imageURL) {
            guard image == nil, let url = show.imageURL else { return }
            if let loaded = await PosterPipeline.image(for: url, maxPixel: maxPixel) {
                withAnimation(.easeInOut(duration: 0.25)) { image = loaded }
            } else {
                failed = true
            }
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
