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
    /// Venue label from UCB as the account page prints it, e.g. "NY - 14TH ST. MAINSTAGE".
    let venueLabel: String
    /// Source id, "ucb_ny" / "ucb_la" — drives timezone + the Wallet pass venue.
    let source: String
    /// Naive venue-local start (ISO), reserved tickets only.
    let start: String?
    /// Inline `<svg>…</svg>` QR markup as UCB renders it.
    let qrSVG: String
    /// Cardholder name (student ID only).
    let name: String?
    /// One-time nonce to release this reservation.
    let releaseNonce: String?
    /// The show's poster URL (from the feed, stamped at reserve time) — drives
    /// the Wallet pass's strip art. Website-reserved tickets may lack it.
    let posterURL: String?

    enum CodingKeys: String, CodingKey {
        case kind, showID, orderID, eventID, title, venueLabel, source, start, qrSVG, name, releaseNonce, posterURL
    }

    init(kind: Kind, showID: String? = nil, orderID: String? = nil, eventID: String? = nil,
         title: String, venueLabel: String = "", source: String, start: String? = nil,
         qrSVG: String, name: String? = nil, releaseNonce: String? = nil,
         posterURL: String? = nil) {
        self.kind = kind; self.showID = showID; self.orderID = orderID; self.eventID = eventID
        self.title = title; self.venueLabel = venueLabel; self.source = source; self.start = start
        self.qrSVG = qrSVG; self.name = name; self.releaseNonce = releaseNonce
        self.posterURL = posterURL
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
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL)
    }
}

extension Ticket {
    var id: String {
        switch kind {
        case .studentID: return "studentID"
        // Prefer the order number; fall back through event id to title+start so
        // two same-titled reserved shows can't collapse to one id.
        case .reserved:  return "reserved/\(orderID ?? eventID ?? "\(title)#\(start ?? "")")"
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

    /// UCB forbids releasing within an hour of showtime. Without a parsed
    /// start we can't tell which side of that line we're on, so don't offer
    /// it — the website still can. `now` is injected (like `isPast`) so a view
    /// that stays open can re-check the cutoff instead of freezing the answer
    /// at first render.
    func isReleasable(now: Date = Date()) -> Bool {
        guard kind == .reserved, releaseNonce != nil, let startDate else { return false }
        return startDate.timeIntervalSince(now) > 3600
    }

    /// "Jun 26 · 7:00 PM", or empty when the start didn't parse — callers
    /// join this with the venue, so falling back to the venue here printed
    /// it twice.
    var whenLabel: String {
        guard let startDate else { return "" }
        return DateUtils.compactDate(startDate, in: cityTimeZone)
            + " · " + DateUtils.timeString(startDate, in: cityTimeZone)
    }

    /// Strip UCB's city/building boilerplate from a venue label:
    /// "NY - 14TH ST. MAINSTAGE" → "MAINSTAGE", "LA - FRANKLIN" → "FRANKLIN".
    /// Delegates to the show list's helper so wallet rows, the ticket detail,
    /// the Wallet pass and show rows all strip the same prefixes.
    static func cleanVenue(_ s: String) -> String {
        Show.cleanVenueName(s)
    }
}
