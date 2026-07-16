import Foundation
import Observation

/// Single source of truth for the UCB talent directory: loads `/talent.json`,
/// caches it for offline, and answers "is this cast name someone we know?"
/// via a normalized-name index.
@MainActor
@Observable
final class TalentStore {
    private(set) var allPeople: [TalentPerson] = []
    private(set) var loaded = false

    /// Normalized full name → person.
    private var byName: [String: TalentPerson] = [:]

    private let service: TalentService

    init(service: TalentService = TalentService()) {
        self.service = service
    }

    func loadInitial() async {
        if allPeople.isEmpty {
            let service = self.service
            if let cached = await Task.detached(priority: .utility, operation: { service.cachedPayload() }).value {
                apply(cached)
            }
        }
        if let payload = try? await service.fetchRemote() {
            apply(payload)
        }
    }

    private func apply(_ payload: TalentPayload) {
        allPeople = payload.people.filter { !$0.slug.isEmpty && !$0.name.isEmpty }
        byName = Dictionary(allPeople.map { (TalentPerson.nameKey($0.name), $0) },
                            uniquingKeysWith: { first, _ in first })
        loaded = !allPeople.isEmpty
    }

    /// Directory entry for a cast-line name, if we can match it.
    func person(named raw: String) -> TalentPerson? {
        byName[TalentPerson.nameKey(raw)]
    }

    /// Directory filtered by search text and an optional group tag.
    func people(matching query: String, group: String? = nil) -> [TalentPerson] {
        var out = allPeople
        if let group { out = out.filter { $0.groups.contains(group) } }
        let q = TalentPerson.nameKey(query)
        if !q.isEmpty { out = out.filter { TalentPerson.nameKey($0.name).contains(q) } }
        return out
    }
}
