import Foundation

/// Fetches a JSON feed and keeps a local "last-good" copy so a tab shows content
/// instantly on launch and survives being offline. One generic replaces the
/// three near-identical per-feed services.
///
/// Application Support (not Caches) persists across launches and isn't purged
/// under storage pressure, so the app always opens with the last data.
struct FeedService<Payload: Decodable> {
    enum FeedError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "The server responded with an error (\(code))."
            }
        }
    }

    private let feedURL: URL
    private let cacheURL: URL
    private let session: URLSession

    init(feed: URL, cacheName: String, session: URLSession = .shared) {
        self.feedURL = feed
        self.cacheURL = AppSupport.file(cacheName)
        self.session = session
    }

    /// Fetch fresh data and refresh the on-disk cache. Protocol cache policy, so
    /// URLSession honors the feed's ETag/max-age — an unchanged feed costs a
    /// ~0-byte 304 revalidation instead of a re-download.
    func fetchRemote() async throws -> Payload {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeedError.badResponse(http.statusCode)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try? data.write(to: cacheURL, options: .atomic)   // best-effort last-good cache
        return payload
    }

    /// Last-good payload from disk, if any.
    func cachedPayload() -> Payload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}

// The three live feeds, committed to the repo by the scheduled scraper workflow
// (UCB every 3h, other sources every 24h) and served from GitHub's raw CDN.
private func liveFeed(_ file: String) -> URL {
    URL(string: "https://raw.githubusercontent.com/salimhafid/improv/main/docs/\(file)")!
}

extension FeedService where Payload == ShowsPayload {
    static var shows: FeedService { FeedService(feed: liveFeed("shows.json"), cacheName: "shows.cache.json") }
}
extension FeedService where Payload == ClassesPayload {
    static var classes: FeedService { FeedService(feed: liveFeed("classes.json"), cacheName: "classes.cache.json") }
}
extension FeedService where Payload == TalentPayload {
    static var talent: FeedService { FeedService(feed: liveFeed("talent.json"),  cacheName: "talent.cache.json") }
}
