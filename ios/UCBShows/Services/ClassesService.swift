import Foundation

/// Fetches the classes feed and keeps a local "last-good" copy so the Classes tab
/// shows content instantly on launch and survives being offline. Mirrors
/// `ShowsService`.
struct ClassesService {
    /// Live classes feed published to GitHub Pages by the scheduled scraper
    /// workflow (see `ShowsService.feedURL`).
    static let feedURL = URL(string: "https://salimhafid.com/improv/classes.json")!

    enum LoadError: LocalizedError {
        case offlineNoCache
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .offlineNoCache: return "Couldn’t reach the server and there’s no saved data yet."
            case .badResponse(let code): return "The server responded with an error (\(code))."
            }
        }
    }

    private let session: URLSession
    private let cacheURL: URL

    init(session: URLSession = .shared) {
        self.session = session
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("UCBShows", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("classes.cache.json")
    }

    /// Fetch fresh data from the network and update the on-disk cache. Protocol
    /// cache policy so unchanged feeds revalidate as a ~0-byte 304 (see
    /// `ShowsService.fetchRemote`).
    func fetchRemote() async throws -> ClassesPayload {
        var request = URLRequest(url: Self.feedURL)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadError.badResponse(http.statusCode)
        }
        let payload = try JSONDecoder().decode(ClassesPayload.self, from: data)
        try? data.write(to: cacheURL, options: .atomic)   // best-effort last-good cache
        return payload
    }

    /// Last-good payload from disk, if any.
    func cachedPayload() -> ClassesPayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ClassesPayload.self, from: data)
    }
}
