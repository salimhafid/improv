import LinkPresentation
import SwiftUI
import UIKit

/// Share-sheet item for a show. Supplies custom LPLinkMetadata so pasting into
/// Messages (and other link-preview surfaces) renders a rich card with the
/// show's title, artwork, date & time, and theater · stage — while the link
/// itself is the theater's own show page, so tapping it opens the real
/// webpage. "Copy" on the share sheet copies that URL.
final class ShowActivityItem: NSObject, UIActivityItemSource {
    private let show: Show
    private let image: UIImage?

    init(show: Show, image: UIImage?) {
        self.show = show
        self.image = image
    }

    /// "The Stepfathers — Friday, July 17 @ 7:00 PM · UCB · NYC · Mainstage"
    private var composedTitle: String {
        var parts: [String] = []
        parts.append(show.dateRaw.isEmpty ? show.timeLabel : show.dateRaw)
        var theater = show.sourceLabel
        if !show.shortVenue.isEmpty { theater += " · \(show.shortVenue)" }
        parts.append(theater)
        return "\(show.title) — \(parts.joined(separator: " · "))"
    }

    private var payload: Any {
        show.url ?? composedTitle as Any
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        payload
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        payload
    }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String {
        composedTitle
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        if let url = show.url {
            metadata.originalURL = url
            metadata.url = url
        }
        metadata.title = composedTitle
        if let image {
            // imageProvider feeds the Messages bubble artwork; iconProvider
            // feeds the share-sheet header thumbnail.
            metadata.imageProvider = NSItemProvider(object: image)
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}

/// UIActivityViewController wrapper (SwiftUI's ShareLink can't supply custom
/// link metadata for the Messages bubble).
struct ShowShareSheet: UIViewControllerRepresentable {
    let show: Show
    let image: UIImage?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [ShowActivityItem(show: show, image: image)],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
