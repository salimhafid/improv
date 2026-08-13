import Foundation

/// A UCB ticket the user holds: either a per-show reserved student ticket, or
/// the persistent standby "UCB Student ID". Persisted as a full value object
/// (like saved I'm-Going shows) so the QR renders offline at the door.
///
/// The QR is stored as its inline SVG markup exactly as UCB renders it —
/// vector, so it scales crisply and never needs the network.
struct Ticket: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case reserved, studentID }

    let kind: Kind
    /// Show identity join (matches `Show.id`), reserved tickets only.
    let showID: String?
    /// WooCommerce order number — needed to release a reservation.
    let orderID: String?
    /// The show's event id (`ST-<eventID>` product).
    let eventID: String?
    let title: String
    /// Venue label from UCB, e.g. "NY – 14th St. Mainstage".
    let venueLabel: String
    /// Source id, "ucb_ny" / "ucb_la" — drives timezone + geofence venue.
    let source: String
    /// Naive venue-local start (ISO), reserved tickets only.
    let start: String?
    /// Inline `<svg>…</svg>` QR markup as UCB renders it.
    let qrSVG: String
    /// Cardholder name (student ID only).
    let name: String?
    /// One-time nonce to release this reservation.
    let releaseNonce: String?

    enum CodingKeys: String, CodingKey {
        case kind, showID, orderID, eventID, title, venueLabel, source, start, qrSVG, name, releaseNonce
    }

    init(kind: Kind, showID: String? = nil, orderID: String? = nil, eventID: String? = nil,
         title: String, venueLabel: String = "", source: String, start: String? = nil,
         qrSVG: String, name: String? = nil, releaseNonce: String? = nil) {
        self.kind = kind; self.showID = showID; self.orderID = orderID; self.eventID = eventID
        self.title = title; self.venueLabel = venueLabel; self.source = source; self.start = start
        self.qrSVG = qrSVG; self.name = name; self.releaseNonce = releaseNonce
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .reserved
        showID = try c.decodeIfPresent(String.self, forKey: .showID)
        orderID = try c.decodeIfPresent(String.self, forKey: .orderID)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Ticket"
        venueLabel = (try c.decodeIfPresent(String.self, forKey: .venueLabel)) ?? ""
        source = (try c.decodeIfPresent(String.self, forKey: .source)) ?? "ucb_ny"
        start = try c.decodeIfPresent(String.self, forKey: .start)
        qrSVG = (try c.decodeIfPresent(String.self, forKey: .qrSVG)) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        releaseNonce = try c.decodeIfPresent(String.self, forKey: .releaseNonce)
    }
}

extension Ticket {
    var id: String {
        switch kind {
        case .studentID: return "studentID"
        case .reserved:  return "reserved/\(orderID ?? eventID ?? title)"
        }
    }

    var venue: Venue? { Venue.forSource(source) }

    var cityTimeZone: TimeZone {
        (source == "ucb_la" ? City.losAngeles : City.newYork).timeZone
    }

    /// Reserved-show start as a `Date`, interpreted in the venue's timezone.
    var startDate: Date? {
        guard let start else { return nil }
        return DateUtils.parse(start, in: cityTimeZone)
    }

    /// True once the show has started (plus a small grace) — used to expire
    /// reserved tickets out of the wallet.
    func isPast(now: Date = Date()) -> Bool {
        guard kind == .reserved, let startDate else { return false }
        return startDate.addingTimeInterval(3 * 3600) < now
    }

    /// UCB forbids releasing within an hour of showtime.
    var isReleasable: Bool {
        guard kind == .reserved, releaseNonce != nil else { return false }
        guard let startDate else { return true }
        return startDate.timeIntervalSinceNow > 3600
    }

    var whenLabel: String {
        guard let startDate else { return venueLabel }
        return DateUtils.compactDate(startDate, in: cityTimeZone)
            + " · " + DateUtils.timeString(startDate, in: cityTimeZone)
    }
}
