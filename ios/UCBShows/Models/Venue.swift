import CoreLocation
import Foundation

/// A physical UCB venue the app can geofence. Coordinates are baked in (the
/// feed carries only a venue *string*), so proximity works with zero backend.
struct Venue: Identifiable, Hashable {
    let id: String            // stable key, e.g. "ucb_ny"
    let name: String          // display, e.g. "UCB 14th Street"
    let address: String
    let latitude: Double
    let longitude: Double
    /// Geofence radius in meters — tight enough to mean "you're here," loose
    /// enough to fire before the door.
    var radius: CLLocationDistance = 200

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var region: CLCircularRegion {
        let r = CLCircularRegion(center: coordinate, radius: radius, identifier: "venue/\(id)")
        r.notifyOnEntry = true
        r.notifyOnExit = false
        return r
    }
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
