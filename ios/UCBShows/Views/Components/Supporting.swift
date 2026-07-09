import SwiftUI
import SafariServices

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
struct WebLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// In-app Safari for opening ticket pages — feels more first-party than handing
/// off to the Safari app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        return vc
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Pinned date section header for the feed.
struct SectionHeaderView: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 8)
            .background(.bar)
    }
}

/// Unobtrusive banner shown when displaying cached data after a failed refresh.
struct OfflineBanner: View {
    let updatedLabel: String?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text(bannerText).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal, Theme.Space.gutter)
    }

    private var bannerText: String {
        if let updatedLabel { return "Showing saved shows · \(updatedLabel.lowercased())" }
        return "Showing saved shows"
    }
}
