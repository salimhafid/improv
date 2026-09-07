import Foundation
import Observation

/// Single source of truth for the UCB talent directory: loads `/talent.json`,
/// caches it for offline, and answers "is this cast name someone we know?"
/// via a normalized-name index.
@MainActor
@Observable
final class TalentStore {
    enum Phase: Equatable {
        case loading        // first load, nothing to show yet
        case loaded         // showing fresh data
        case offline        // showing cached data, refresh failed
        case failed(String) // nothing to show and refresh failed
    }

    private(set) var phase: Phase = .loading
    private(set) var allPeople: [TalentPerson] = []
    /// A non-empty directory is on hand (cached or fresh) — what the cast
    /// chips and the directory view key on.
    private(set) var loaded = false

    /// Normalized full name → person.
    private var byName: [String: TalentPerson] = [:]
    /// (nameKey, person) pairs precomputed at apply() — the directory search
    /// filters on these instead of re-normalizing every name per keystroke.
    private var keyedPeople: [(String, TalentPerson)] = []
    /// Profile slug → person (exact matches for structured cast).
    private var bySlug: [String: TalentPerson] = [:]

    private let service: FeedService<TalentPayload>

    init(service: FeedService<TalentPayload> = .talent) {
        self.service = service
    }

    /// Show cached data instantly (if any), then refresh from the network —
    /// the same shape as the shows and classes stores.
    func loadInitial() async {
        if allPeople.isEmpty {
            let service = self.service
            if let cached = await Task.detached(priority: .utility, operation: { service.cachedPayload() }).value {
                apply(cached)
                phase = .loaded
            }
        }
        await refresh(force: false)
    }

    /// Refresh from the network; the directory's retry and pull-to-refresh.
    /// `force` — the default, since every caller outside the store is the
    /// user — revalidates with the origin even inside the CDN's max-age, so
    /// an explicit refresh can't "succeed" out of `URLCache` while offline.
    func refresh(force: Bool = true) async {
        do {
            let payload = try await service.fetchRemote(
                policy: force ? .reloadRevalidatingCacheData : .useProtocolCachePolicy)
            apply(payload)
            phase = .loaded
        } catch {
            phase = allPeople.isEmpty ? .failed(error.localizedDescription) : .offline
        }
    }

    /// The single write path for directory data — both loaders above go
    /// through it, as does the offline logic harness (which has no network
    /// and no bundle cache to load from).
    func apply(_ payload: TalentPayload) {
        allPeople = payload.people.filter { !$0.slug.isEmpty && !$0.name.isEmpty }
        keyedPeople = allPeople.map { (TalentPerson.nameKey($0.name), $0) }
        byName = Dictionary(keyedPeople,
                            uniquingKeysWith: { first, _ in first })
        bySlug = Dictionary(allPeople.map { ($0.slug, $0) },
                            uniquingKeysWith: { first, _ in first })
        loaded = !allPeople.isEmpty
    }

    /// Directory entry for a cast-line name, if we can match it.
    func person(named raw: String) -> TalentPerson? {
        byName[TalentPerson.nameKey(raw)]
    }

    /// Exact directory entry for a structured cast member.
    func person(slug: String) -> TalentPerson? {
        bySlug[slug]
    }

    /// Best match for a cast entry: exact slug first, then normalized name.
    func person(for member: CastMember) -> TalentPerson? {
        if let slug = member.slug, let hit = bySlug[slug] { return hit }
        return person(named: member.name)
    }

    /// Directory filtered by search text and an optional city tag. The city
    /// filters are mutually exclusive: LA membership wins, so bicoastal
    /// performers appear only under Los Angeles. DCM talent and teachers count
    /// as New York (the marathon is a NY institution, and that is the city
    /// `cityLabel` tags them with) unless they're also on the LA roster.
    func people(matching query: String, group: String? = nil) -> [TalentPerson] {
        // Filter on the name keys precomputed at apply() time — nameKey runs
        // two regex replacements, and recomputing it for ~1,700 people per
        // keystroke made search typing visibly laggy.
        var out = keyedPeople
        if let group {
            out = out.filter { _, person in
                group == "ny" ? person.cityLabel == "New York" : person.groups.contains(group)
            }
        }
        let q = TalentPerson.nameKey(query)
        if !q.isEmpty { out = out.filter { key, _ in key.contains(q) } }
        return out.map(\.1)
    }
}
