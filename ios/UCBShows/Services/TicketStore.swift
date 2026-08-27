import Foundation
import Observation
import UserNotifications

/// The user's UCB tickets: reserved student tickets + the persistent standby
/// "UCB Student ID". Reads them from the account, persists full value objects
/// to Application Support (so QR renders offline), and keeps the near-venue
/// notifications + showtime reminders in sync — mirroring `GoingStore`.
@MainActor
@Observable
final class TicketStore {
    private(set) var reserved: [Ticket] = []
    private(set) var studentID: Ticket?

    /// Set once at app composition (strong; no cycle back to us).
    var account: UCBAccountStore?

    /// Set once at app composition (strong; no cycle back to us). We tell it
    /// which shows we hold tickets to so it stands its own reminder down —
    /// assigning it re-arms, because tickets loaded from disk in `init` land
    /// before this wiring.
    var going: GoingStore? { didSet { reconcileReminders() } }

    /// Set once at app composition (strong; no cycle back to us). The only
    /// source of show identity for a ticket the user already holds — assigning
    /// it backfills, in case the feed landed before the wallet did.
    var shows: ShowsStore? { didSet { backfillShowJoins() } }

    private let fileURL = AppSupport.file("tickets.json")

    init() {
        load()
        // Another device changed the tickets via iCloud — reload them live.
        NotificationCenter.default.addObserver(
            forName: CloudSync.fileDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard note.object as? String == "tickets.json" else { return }
            MainActor.assumeIsolated { self?.reloadFromCloud() }
        }
        // Whichever feature obtained the grant, ours has to re-arm: anything
        // we tried to schedule while unauthorized was rejected, not queued.
        NotificationCenter.default.addObserver(
            forName: NotificationAuth.didGrant, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileReminders() }
        }
    }

    var hasAnything: Bool { studentID != nil || !reserved.isEmpty }

    func ticket(id: String) -> Ticket? {
        if id == "studentID" { return studentID }
        return reserved.first { $0.id == id }
    }

    // MARK: Sync from the account

    /// Pull the latest tickets from UCB and re-arm everything. Reports whether
    /// the read actually landed, so a caller that needs the result (a reserve
    /// waiting for its ticket) can retry.
    @discardableResult
    func sync() async -> Bool {
        #if DEBUG
        if DebugFixtures.fakeTickets { return false }   // keep seeded fixtures stable
        #endif
        guard let account else { return false }
        return adopt(await account.refresh())
    }

    private var lastSynced: Date?

    /// Tab-visit sync: skip if we synced recently, so switching to the Tickets
    /// tab is instant instead of kicking off a UCB page load every time.
    /// Pull-to-refresh uses `sync()` directly and is always fresh.
    func syncIfStale(maxAge: TimeInterval = 5 * 60) async {
        if let lastSynced, Date().timeIntervalSince(lastSynced) < maxAge { return }
        await sync()
    }

    /// Apply a refresh outcome. `unknown` (transient / interstitial) is a no-op,
    /// so a bad read never wipes the offline cache. Reports whether it applied,
    /// so the caller can leave a failed read eligible for an immediate retry.
    ///
    /// Only a read that actually landed starts the staleness clock — a
    /// transient one applies nothing, and stamping it would sit on an empty
    /// wallet (and an unarmed reminder) for five minutes after a reserve. The
    /// stamp lives here rather than in `sync()` because launch shares ONE
    /// account read with the wallet: without it, the Tickets tab treated the
    /// launch read as never having happened and kicked off a second, serialized
    /// ucbcomedy.com navigation the moment it appeared.
    @discardableResult
    func adopt(_ outcome: UCBSession.RefreshOutcome) -> Bool {
        switch outcome {
        case .signedIn(let snap): apply(snap); lastSynced = Date(); return true
        case .signedOut: clearLocal(); lastSynced = Date(); return true
        case .unknown: return false
        }
    }

    private func apply(_ snap: UCBSession.AccountSnapshot) {
        // The account page carries the showtime but never the show's identity
        // or poster art — and its meta line occasionally fails to parse, which
        // would drop the `start` that drives reminders, expiry, and the release
        // gate. Carry whatever we learned at reserve time forward, by order id.
        let prior = Dictionary(reserved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        reserved = snap.tickets.map { t in
            guard let old = prior[t.id],
                  t.showID == nil || t.start == nil || t.posterURL == nil else { return t }
            // `start` is naive venue-local, so it only means anything alongside
            // the source it was read in — those two always travel together.
            let keepOldStart = t.start == nil && old.start != nil
            return Ticket(kind: .reserved, showID: t.showID ?? old.showID, orderID: t.orderID,
                          eventID: t.eventID ?? old.eventID, title: t.title,
                          venueLabel: t.venueLabel,
                          source: keepOldStart ? old.source : t.source,
                          start: keepOldStart ? old.start : t.start,
                          qrSVG: t.qrSVG, releaseNonce: t.releaseNonce,
                          posterURL: t.posterURL ?? old.posterURL)
        }.filter { !$0.isPast() }
        // Same carry-forward as `reserved` above, for the same reason: a
        // partially-rendered account page yields an empty SVG while still
        // reading as signed in, and dropping the card here would delete the
        // user's Student ID QR (and push that deletion to iCloud). Only a
        // definitive signed-out clears it, and that goes through `clearLocal`.
        if !snap.studentIDSVG.isEmpty {
            studentID = Ticket(kind: .studentID, title: "UCB Student ID", venueLabel: "",
                               source: "ucb_ny", qrSVG: snap.studentIDSVG, name: snap.name)
        }
        joinShows()
        save()
        reconcileReminders()
    }

    /// Drop all local ticket state + reminders (sign-out / definitive signed-out).
    /// Nothing held means nothing to clear, and the early return matters:
    /// `save()` here publishes an empty `tickets.json` to iCloud, which would
    /// let a device that never had a UCB session empty the wallet — and cancel
    /// the reminders — on the device that does.
    func clearLocal() {
        guard hasAnything else { return }
        reserved = []
        studentID = nil
        pendingJoins = []
        save()
        cancelAllReminders()
    }

    // MARK: The show ↔ ticket join

    /// Shows reserved in-app whose ticket hasn't landed in a read yet. A
    /// reserve whose follow-up read came back `unknown` parks its intent here,
    /// so the next applied read still stamps the join.
    private var pendingJoins: [Show] = []

    /// Stamp reserved tickets with the show they belong to: identity and poster
    /// (the account page carries neither), plus the start when UCB's meta line
    /// didn't parse. The identity is the dedupe key that lets `GoingStore` stand
    /// its own reminder down, so it has to reach tickets the user ALREADY holds
    /// — reserved on ucbtheatre.com, or restored from iCloud — not just the one
    /// just reserved. Outstanding reserve intents go first (they name the exact
    /// show the user tapped); anything still unjoined falls back to the live
    /// feed, and only when the match there is unambiguous. Reports whether
    /// anything changed, so callers save and re-arm at most once.
    @discardableResult
    private func joinShows() -> Bool {
        var changed = false
        pendingJoins.removeAll { show in
            guard let i = unjoinedTicket(for: show) else {
                // Keep waiting unless the show is over: the ticket may still be
                // one failed read away, but it can't arrive after showtime.
                return (show.startDate ?? .distantFuture) < Date()
            }
            stamp(show, onto: i)
            changed = true
            return true
        }
        let feed = shows?.allShows ?? []
        guard !feed.isEmpty else { return changed }
        for i in reserved.indices where reserved[i].showID == nil {
            guard let match = ReminderPlan.uniqueBooking(ticketTitle: reserved[i].title,
                                                         ticketStart: reserved[i].startDate,
                                                         in: feed) else { continue }
            stamp(match, onto: i)
            changed = true
        }
        return changed
    }

    /// Close the join from the other side: a ticket read before the shows feed
    /// landed had nothing to match against.
    func backfillShowJoins() {
        guard joinShows() else { return }
        save()
        reconcileReminders()
    }

    /// The unstamped ticket this show produced, if it has landed yet.
    private func unjoinedTicket(for show: Show) -> Int? {
        reserved.firstIndex { t in
            t.showID == nil && ReminderPlan.sameBooking(
                ticketTitle: t.title, ticketStart: t.startDate,
                showTitle: show.title, showStart: show.startDate,
                in: show.cityTimeZone)
        }
    }

    /// Copy a show's identity and poster onto the ticket at `i`, plus its start
    /// when UCB's own didn't parse. UCB's showtime wins when it did — it's the
    /// authoritative one — and `start` is naive venue-local, so it only means
    /// anything alongside the `source` it was read in; those two travel together.
    private func stamp(_ show: Show, onto i: Int) {
        let t = reserved[i]
        let keepScraped = t.start != nil
        reserved[i] = Ticket(kind: .reserved, showID: show.id, orderID: t.orderID,
                             eventID: t.eventID, title: t.title, venueLabel: t.venueLabel,
                             source: keepScraped ? t.source : show.source,
                             start: keepScraped ? t.start : show.start, qrSVG: t.qrSVG,
                             releaseNonce: t.releaseNonce,
                             posterURL: show.imageString ?? t.posterURL)
    }

    // MARK: Reserve / release (run inside the session web view)

    func reserve(show: Show) async -> UCBSession.ActionResult {
        guard let account, let url = show.url else {
            return .init(success: false, message: "Sign in to UCB to reserve.")
        }
        // Ask BEFORE the round trip. The tap is the notifiable action, and this
        // is the only moment we know the user is still looking at this show:
        // the reserve below is two serialized 20-second web navigations, and
        // asking after them surfaced the system alert on whatever screen the
        // user had moved on to. Nothing is armed here — `apply` does that once
        // the ticket lands, and a fresh grant also fans out via
        // `NotificationAuth.didGrant`. Skipped for a show already inside the
        // reminder's lead time: there'd be nothing to notify about.
        if show.startDate.flatMap({ ReminderPlan.fireDate(forStart: $0) }) != nil {
            await NotificationAuth.ensure()
        }
        let result = await account.session.reserve(showURL: url)
        guard result.success else { return result }
        // Park the join intent before syncing: it carries the show identity the
        // reminder dedupe needs, and the account page never carries it. A read
        // that comes back `unknown` then loses nothing — one retry here, and
        // `joinShows` picks up whatever is still pending on the next read.
        pendingJoins.append(show)
        if await sync() == false { await sync() }
        return result
    }

    @discardableResult
    func release(_ ticket: Ticket) async -> Bool {
        guard let account, let order = ticket.orderID, let nonce = ticket.releaseNonce else { return false }
        let result = await account.session.release(order: order, nonce: nonce)
        if result.success { await sync() }
        return result.success
    }

    // MARK: Reminders (near-venue surfacing lives in the Wallet pass now)

    private nonisolated static let reminderPrefix = "ticket/"

    /// True when a held ticket is still far enough out that a reminder could
    /// actually be scheduled — the gate on asking for permission, so we never
    /// prompt a user who has nothing to be reminded about.
    private var hasRemindableTicket: Bool {
        reserved.contains { ticket in
            ticket.startDate.flatMap { ReminderPlan.fireDate(forStart: $0) } != nil
        }
    }

    /// A definitive account read landed this session, so `reserved` describes
    /// what UCB says the user holds — not whatever the disk cache (or an iCloud
    /// restore) left in memory at launch.
    private var walletIsConfirmed: Bool { lastSynced != nil }

    /// Ask for permission to notify at a moment the user understands: they just
    /// opened the Tickets tab holding a ticket that's still hours out. Silent
    /// unless a signed-in, freshly confirmed wallet actually has something to
    /// remind about — asking off the disk cache prompted users whose UCB
    /// session had expired about tickets the very next read was about to
    /// delete. iOS shows the prompt once per install, so a user who declined is
    /// never re-asked. Never call this from a background sync.
    func ensureReminderAuthorization() async {
        guard account?.isSignedIn == true, walletIsConfirmed, hasRemindableTicket else { return }
        guard await NotificationAuth.ensure() else { return }
        // Re-arm whatever was dropped while unauthorized (a fresh grant also
        // fans out via `NotificationAuth.didGrant`; this covers the
        // already-authorized case too). Idempotent — `add` replaces by
        // identifier.
        reconcileReminders()
    }

    /// Cancel reminders for tickets no longer held, (re)schedule the current
    /// set, and publish the covered shows so `GoingStore` stands down.
    private func reconcileReminders() {
        let center = UNUserNotificationCenter.current()
        let keep = Set(reserved.map { "\(Self.reminderPrefix)\($0.id)" })
        Task {
            let pending = await center.pendingNotificationRequests()
            let stale = pending.map(\.identifier)
                .filter { $0.hasPrefix(Self.reminderPrefix) && !keep.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        }
        for ticket in reserved {
            guard let start = ticket.startDate,
                  let fireAt = ReminderPlan.fireDate(forStart: start) else { continue }
            let content = UNMutableNotificationContent()
            content.title = ticket.title
            content.body = "Starts in an hour at \(Venue.forSource(ticket.source)?.name ?? "UCB")."
            content.sound = .default
            content.userInfo = ["ticketID": ticket.id]
            // An absolute offset, not wall-clock components: a calendar trigger
            // re-matches in whatever timezone the phone is in when it fires, so
            // an NY ticket would misfire after the user flies to LA.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSinceNow,
                                                            repeats: false)
            center.add(UNNotificationRequest(identifier: "\(Self.reminderPrefix)\(ticket.id)",
                                             content: content, trigger: trigger))
        }
        publishCoverage()
    }

    /// Tell `GoingStore` what our tickets already cover, so exactly one reminder
    /// fires per show — ours, because tapping it opens the QR.
    private func publishCoverage() {
        var coverage = ReminderCoverage(showIDs: Set(reserved.compactMap(\.showID)))
        // Tickets reserved on ucbtheatre.com never passed through the in-app
        // reserve that stamps the join — publish title + start so a show
        // hearted later is still recognised.
        for ticket in reserved where ticket.showID == nil {
            guard let start = ticket.startDate else { continue }
            coverage.events.append(.init(title: ticket.title, start: start))
        }
        going?.setTicketCoverage(coverage)
    }

    private func cancelAllReminders() {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
        // Nothing is covered any more — hearted shows take their reminders back.
        going?.setTicketCoverage(ReminderCoverage())
    }

    #if DEBUG
    /// Screenshot-verification hook (see DebugFixtures): in-memory only, never
    /// saved, no reminders/geofences armed.
    func debugSeed(studentID: Ticket, reserved: [Ticket]) {
        self.studentID = studentID
        self.reserved = reserved
    }
    #endif

    // MARK: Persistence

    private struct Saved: Codable { var reserved: [Ticket]; var studentID: Ticket? }

    private func decodeSaved() -> Saved? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            AppSupport.moveAside(fileURL)
            return nil
        }
        return saved
    }

    private func load() {
        guard let saved = decodeSaved() else { return }
        adoptSaved(saved)
    }

    /// Reload after ANOTHER device rewrote tickets.json. Deliberately more
    /// conservative than `load()`: a device that legitimately hit a definitive
    /// signed-out publishes an empty wallet, and adopting that here would empty
    /// a wallet this device is still holding — cancelling the very reminders
    /// the user needs tonight. An empty remote payload is therefore ignored
    /// while we hold anything; the local session's own `clearLocal()` is what
    /// clears this device. Payloads that add or update tickets are adopted
    /// normally.
    private func reloadFromCloud() {
        guard let saved = decodeSaved() else { return }
        let remoteIsEmpty = saved.studentID == nil && !saved.reserved.contains { !$0.isPast() }
        guard !(remoteIsEmpty && hasAnything) else { return }
        adoptSaved(saved)
    }

    private func adoptSaved(_ saved: Saved) {
        reserved = saved.reserved.filter { !$0.isPast() }
        studentID = saved.studentID
        // Arm on every load, not just after a successful account refresh: a
        // cold launch offline (or one that lands on UCB's interstitial) never
        // reaches `apply`, and a fresh install adopting tickets.json from
        // iCloud never reaches it either. Pending requests survive relaunches
        // and `add` replaces by identifier, so this is idempotent.
        reconcileReminders()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(reserved: reserved, studentID: studentID)) {
            try? data.write(to: fileURL, options: .atomic)
            CloudSync.pushFile("tickets.json", data)
        }
    }
}
