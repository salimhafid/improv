import Foundation
import Observation

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

    /// Fetch fresh data and refresh the on-disk cache. The default protocol
    /// cache policy lets URLSession honor the feed's ETag/max-age — an
    /// unchanged feed costs a ~0-byte 304 revalidation instead of a
    /// re-download — but inside the CDN's max-age window it also answers
    /// straight out of `URLCache`, offline included. Explicit refreshes pass
    /// `.reloadRevalidatingCacheData` so they always reach the origin.
    func fetchRemote(policy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Payload {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = policy
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeedError.badResponse(http.statusCode)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try Task.checkCancellation()
        try? data.write(to: cacheURL, options: .atomic)   // best-effort last-good cache
        return payload
    }

    /// Last-good payload from disk, if any.
    func cachedPayload() -> Payload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}

/// One refresh at a time per feed, including its disk-cache read and write.
@MainActor
@Observable
final class FeedLoader<Payload: Decodable & Sendable> {
    enum Phase: Equatable {
        case loading, loaded, offline, failed(String)
    }

    private(set) var phase: Phase = .loading
    private let service: FeedService<Payload>
    @ObservationIgnored private var checkedDisk = false
    @ObservationIgnored private var hasPayload = false
    @ObservationIgnored private var lastFetched: Date?
    @ObservationIgnored private var inFlight: URLRequest.CachePolicy?
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(_ service: FeedService<Payload>) {
        self.service = service
    }

    static func isStale(lastFetched: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let lastFetched else { return true }
        let age = now.timeIntervalSince(lastFetched)
        return age > maxAge || age < 0
    }

    func refreshIfStale(maxAge: TimeInterval, apply: @escaping (Payload) -> Void) async {
        guard !Task.isCancelled else { return }
        // Navigation can cancel one view while another still needs this feed.
        await Task {
            guard Self.isStale(lastFetched: lastFetched, now: Date(), maxAge: maxAge) else { return }
            await refresh(force: false, apply: apply)
        }.value
    }

    func refresh(force: Bool, apply: (Payload) -> Void) async {
        // Share equivalent requests. A pull or alert arriving during an automatic
        // check still needs a revalidation, after the first request has finished.
        while let policy = inFlight {
            let finished = await withCheckedContinuation { waiters.append($0) }
            if finished && (!force || policy == .reloadRevalidatingCacheData) { return }
        }
        guard !Task.isCancelled else { return }
        let policy: URLRequest.CachePolicy = force ? .reloadRevalidatingCacheData : .useProtocolCachePolicy
        inFlight = policy
        var finished = false
        defer {
            inFlight = nil
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume(returning: finished) }
        }
        if !checkedDisk {
            let service = self.service
            let cached = await Task.detached(priority: .utility) { service.cachedPayload() }.value
            guard !Task.isCancelled else { return }
            checkedDisk = true
            if let cached {
                apply(cached)
                hasPayload = true
                phase = .loaded
            }
        }
        do {
            let payload = try await service.fetchRemote(policy: policy)
            try Task.checkCancellation()
            apply(payload)
            hasPayload = true
            lastFetched = Date()
            phase = .loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            lastFetched = nil
            phase = hasPayload ? .offline : .failed(error.localizedDescription)
        }
        finished = true
    }
}

// The three live feeds, committed to the repo by the scheduled scraper workflow
// (UCB NY every 3h, every other source every 24h) and served from GitHub's raw CDN.
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
