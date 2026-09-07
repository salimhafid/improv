import Foundation

/// Shared Application Support location for the app's on-device JSON (feed
/// caches, I'm-Going list, tickets). One place for the directory bootstrap that
/// was previously copy-pasted into every store and service.
enum AppSupport {
    /// `~/Library/Application Support/UCBShows/<name>` (directory created),
    /// falling back to Caches if Application Support is unavailable.
    static func file(_ name: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("UCBShows", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Park an unreadable file aside (`<name>.bak-<unix seconds>.json`) instead
    /// of losing it, so a corrupt cache can't be silently overwritten on the
    /// next save. Timestamped, so a second corruption doesn't destroy the first
    /// backup either.
    static func moveAside(_ url: URL, now: Date = Date()) {
        let name = url.deletingPathExtension().lastPathComponent
        let bak = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).bak-\(Int(now.timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: bak)
    }
}
