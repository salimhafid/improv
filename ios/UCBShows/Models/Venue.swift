import Foundation

/// A physical UCB venue. Coordinates are baked in (the feed carries only a
/// venue *string*) and feed the Wallet pass's `locations`, which is what
/// surfaces the pass on the lock screen near the theater — the app itself
/// uses no location services.
struct Venue: Identifiable, Hashable {
    let id: String            // stable key, e.g. "ucb_ny"
    let name: String          // display, e.g. "UCB 14th Street"
    let address: String
    let latitude: Double
    let longitude: Double
}

extension Venue {
    /// The known UCB venues. Every `ucb_ny` show is at 14th Street (242 E 14th);
    /// `ucb_la` shows are at the Franklin theater.
    static let ucbNewYork = Venue(
        id: "ucb_ny", name: "UCB 14th Street", address: "242 E 14th St, New York, NY 10003",
        latitude: 40.733100, longitude: -73.985300)

    static let ucbLosAngeles = Venue(
        id: "ucb_la", name: "UCB Franklin", address: "5919 Franklin Ave, Los Angeles, CA 90028",
        latitude: 34.104960, longitude: -118.322330)

    static let all: [Venue] = [ucbNewYork, ucbLosAngeles]

    /// The venue a show plays, by its source id. Only UCB shows have a mapped
    /// venue today (they're the only theater with student ticketing).
    static func forSource(_ source: String) -> Venue? {
        all.first { $0.id == source }
    }
}
