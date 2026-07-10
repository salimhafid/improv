import Foundation

/// Fetches the shows feed and keeps a local "last-good" copy so the app shows
/// content instantly on launch and survives being offline.
struct ShowsService {
    /// Live feed produced by the Cloud Run scraper (refreshed on a schedule
    /// server-side: UCB New York every 6h, other sources every 24h).
    static let feedURL = URL(string: "https://ucb-ny-shows-315881650478.us-central1.run.app/shows.json")!

    enum LoadError: LocalizedError {
        case offlineNoCache
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .offlineNoCache: return "Couldn’t reach UCB and there’s no saved data yet."
            case .badResponse(let code): return "The server responded with an error (\(code))."
            }
        }
    }

    private let session: URLSession
    private let cacheURL: URL

    init(session: URLSession = .shared) {
        self.session = session
        // Application Support persists across launches and isn't purged under
        // storage pressure like Caches, so the app always opens with last data.
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("UCBShows", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("shows.cache.json")
    }

    /// Fetch fresh data from the network and update the on-disk cache. Uses the
    /// protocol cache policy so URLSession honors the server's ETag/max-age —
    /// unchanged feeds cost a ~0-byte 304 revalidation instead of a re-download.
    func fetchRemote() async throws -> ShowsPayload {
        var request = URLRequest(url: Self.feedURL)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadError.badResponse(http.statusCode)
        }
        let payload = try JSONDecoder().decode(ShowsPayload.self, from: data)
        try? data.write(to: cacheURL, options: .atomic)   // best-effort last-good cache
        return payload
    }

    /// Last-good payload from disk, if any.
    func cachedPayload() -> ShowsPayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ShowsPayload.self, from: data)
    }
}
