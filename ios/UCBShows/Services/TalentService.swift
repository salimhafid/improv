import Foundation

/// Fetches the UCB talent directory feed and keeps a local "last-good" copy.
/// Mirrors `ShowsService`.
struct TalentService {
    /// Talent directory published to GitHub Pages by the scrape workflow.
    static let feedURL = URL(string: "https://salimhafid.com/improv/talent.json")!

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
        self.cacheURL = dir.appendingPathComponent("talent.cache.json")
    }

    func fetchRemote() async throws -> TalentPayload {
        var request = URLRequest(url: Self.feedURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(TalentPayload.self, from: data)
        try? data.write(to: cacheURL, options: .atomic)
        return payload
    }

    func cachedPayload() -> TalentPayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(TalentPayload.self, from: data)
    }
}
