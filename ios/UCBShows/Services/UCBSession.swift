import Foundation
import WebKit

/// The app's UCB "session engine." UCB has no API and sits behind Cloudflare
/// Turnstile + JA3 binding, so credentials can't be POSTed natively and cookies
/// can't be lifted into URLSession. Instead ONE persistent `WKWebView` (backed
/// by a named, on-device data store) is BOTH the login surface and the API
/// client: the user signs in inside it once, and every authenticated call runs
/// *inside the same web view* via injected `fetch()` / DOM reads — so requests
/// carry the real cookies + TLS fingerprint. Nothing hits a server we run.
///
/// One web view means operations must not overlap, so they're serialized behind
/// a small async lock, every navigation is bounded by a timeout (so a stalled
/// load can never wedge the lock), and while the login sheet is driving the web
/// view, off-screen ops stand down.
@MainActor
final class UCBSession {
    static let accountURL = URL(string: "https://ucbcomedy.com/my-account/")!
    static let studentTicketsURL = URL(string: "https://ucbcomedy.com/my-account/student-tickets/")!

    private static let storeID = UUID(uuidString: "B9F4C1A2-7E33-49D0-8C21-000000000001")!
    let dataStore: WKWebsiteDataStore = .init(forIdentifier: storeID)

    /// The ENGINE web view: permanently off-screen, never installed in a window,
    /// never touched — it only loads pages and runs injected JS. Keeping it out
    /// of the view hierarchy entirely means UIKit's touch machinery can never
    /// interact with it (moving a live web view in/out of windows mid-gesture
    /// crashes UIKit's delayed-touch bookkeeping).
    let web: WKWebView

    init() {
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 900),
                        configuration: Self.configuration(store: dataStore))
    }

    private static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        return cfg
    }

    /// A fresh LOGIN web view for the sign-in sheet, over the SAME data store —
    /// same network process, same cookie jar — so the cookies the user earns by
    /// logging in are immediately visible to the engine's calls. The sheet owns
    /// it outright and it dies with the sheet: never reused, never reparented,
    /// so no gesture state can outlive its window.
    func makeLoginWebView() -> WKWebView {
        WKWebView(frame: .zero, configuration: Self.configuration(store: dataStore))
    }

    // MARK: Types

    struct AccountSnapshot {
        var name: String
        var eligible: Bool
        var freeRemaining: Int
        var studentIDSVG: String
        var tickets: [Ticket]
    }

    /// Tri-state so a transient interstitial (neither the login form nor account
    /// markers) is `.unknown` and never mistaken for an empty signed-in account.
    enum RefreshOutcome { case signedIn(AccountSnapshot), signedOut, unknown }

    struct ClaimAvailability {
        var available: Bool
        var alreadyClaimed: Bool
        var event: String?
        var nonce: String?
        static let none = ClaimAvailability(available: false, alreadyClaimed: false, event: nil, nonce: nil)
    }

    struct ActionResult {
        var success: Bool
        var message: String
        var alreadyClaimed: Bool = false
    }

    // MARK: Serial lock + login stand-down

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loginActive = false

    private func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// The sign-in sheet claims the web view: abort any in-flight op load (it
    /// fails out and releases the lock) and make new ops stand down.
    func beginLogin() {
        loginActive = true
        web.stopLoading()
        availabilityCache.removeAll()
    }
    func endLogin() { loginActive = false }

    // MARK: Bounded navigation + JS

    private static let loadTimeout: Duration = .seconds(20)

    private func load(_ url: URL) async throws {
        let g = NavGate()
        web.navigationDelegate = g
        web.load(URLRequest(url: url))
        let timeout = Task { try? await Task.sleep(for: Self.loadTimeout); g.cancel() }
        defer { timeout.cancel() }
        do { try await g.wait() }
        catch { web.stopLoading(); throw error }
        try? await Task.sleep(for: .milliseconds(300))  // let client-rendered QR SVG paint
    }

    private func evalDict(_ js: String) async -> [String: Any]? {
        (try? await web.evaluateJavaScript(js)) as? [String: Any]
    }

    private var onUCBOrigin: Bool { web.url?.host?.contains("ucbcomedy.com") ?? false }

    // MARK: Public API (each self-contained + serialized)

    func refresh() async -> RefreshOutcome {
        if loginActive { return .unknown }
        await lock(); defer { unlock() }
        if loginActive { return .unknown }
        // Account state may have changed (quota spent, ticket released on the
        // website) — cached per-show claim reads are no longer trustworthy.
        availabilityCache.removeAll()
        guard (try? await load(Self.studentTicketsURL)) != nil,
              let d = await evalDict(Self.readAccountJS) else { return .unknown }
        switch d["state"] as? String {
        case "signedIn": return .signedIn(Self.parseSnapshot(d))
        case "signedOut": return .signedOut
        default: return .unknown
        }
    }

    func claimAvailability(showURL: URL) async -> ClaimAvailability {
        if let hit = availabilityCache[showURL.absoluteString],
           Date().timeIntervalSince(hit.at) < Self.availabilityTTL { return hit.value }
        if loginActive { return .none }
        await lock(); defer { unlock() }
        if loginActive { return .none }
        guard (try? await load(showURL)) != nil, let d = await evalDict(Self.readClaimJS) else { return .none }
        let a = ClaimAvailability(
            available: (d["available"] as? Bool) ?? false,
            alreadyClaimed: (d["alreadyClaimed"] as? Bool) ?? false,
            event: d["event"] as? String, nonce: d["nonce"] as? String)
        // Cache only positive reads. A negative can be a transient challenge
        // page (Cloudflare renders with HTTP 200), and caching it would hide
        // the reserve button for the rest of the session.
        if a.available || a.alreadyClaimed {
            availabilityCache[showURL.absoluteString] = (a, Date())
        }
        return a
    }

    /// Load the show page, read the live claim control, and (if present) claim —
    /// atomically, so nothing navigates away between the read and the POST.
    func reserve(showURL: URL) async -> ActionResult {
        if loginActive { return ActionResult(success: false, message: "Try again in a moment.") }
        await lock(); defer { unlock() }
        availabilityCache.removeValue(forKey: showURL.absoluteString)
        guard (try? await load(showURL)) != nil, let d = await evalDict(Self.readClaimJS) else {
            return ActionResult(success: false, message: "Couldn’t reach UCB. Try again.")
        }
        if (d["alreadyClaimed"] as? Bool) == true {
            return ActionResult(success: false, message: "Already reserved.", alreadyClaimed: true)
        }
        guard (d["available"] as? Bool) == true,
              let event = d["event"] as? String, let nonce = d["nonce"] as? String else {
            return ActionResult(success: false, message: "No student tickets available for this show.")
        }
        return await post(action: "ucb_student_claim", params: ["event": event, "nonce": nonce])
    }

    func release(order: String, nonce: String) async -> ActionResult {
        if loginActive { return ActionResult(success: false, message: "Try again in a moment.") }
        await lock(); defer { unlock() }
        availabilityCache.removeAll()
        if !onUCBOrigin { _ = try? await load(Self.studentTicketsURL) }
        return await post(action: "ucb_student_release", params: ["order": order, "nonce": nonce])
    }

    func signOut() async {
        await lock(); defer { unlock() }
        availabilityCache.removeAll()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                   modifiedSince: .distantPast)
    }

    /// Short-lived per-show claim cache (positives only) so re-opening a show
    /// doesn't re-navigate, without letting stale state outlive reality.
    private var availabilityCache: [String: (value: ClaimAvailability, at: Date)] = [:]
    private static let availabilityTTL: TimeInterval = 10 * 60

    // MARK: admin-ajax POST (awaits the fetch Promise via callAsyncJavaScript)

    private func post(action: String, params: [String: String]) async -> ActionResult {
        var body = "action=\(action)"
        for (k, v) in params {
            body += "&\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)"
        }
        // callAsyncJavaScript runs an async function body and RESOLVES the
        // promise (evaluateJavaScript would hand back the pending promise).
        let fn = """
        const r = await fetch('https://ucbcomedy.com/wp-admin/admin-ajax.php', {
          method:'POST', credentials:'same-origin',
          headers:{'Content-Type':'application/x-www-form-urlencoded'}, body
        });
        const j = await r.json();
        return { ok: !!j.success, msg: (j.data && j.data.message) || '' };
        """
        let result = try? await web.callAsyncJavaScript(
            fn, arguments: ["body": body], contentWorld: .page)
        guard let d = result as? [String: Any] else {
            return ActionResult(success: false, message: "Something went wrong. Please try again.")
        }
        return ActionResult(success: (d["ok"] as? Bool) ?? false, message: (d["msg"] as? String) ?? "")
    }

    // MARK: Parsing

    private static func parseSnapshot(_ d: [String: Any]) -> AccountSnapshot {
        var tickets: [Ticket] = []
        for t in (d["tickets"] as? [[String: Any]]) ?? [] {
            tickets.append(Ticket(
                kind: .reserved, showID: nil, orderID: t["order"] as? String,
                eventID: t["event"] as? String,
                title: (t["title"] as? String) ?? "UCB show",
                venueLabel: (t["venue"] as? String) ?? "",
                source: (t["source"] as? String) ?? "ucb_ny",
                start: t["start"] as? String,
                qrSVG: (t["svg"] as? String) ?? "",
                releaseNonce: t["nonce"] as? String))
        }
        return AccountSnapshot(
            name: (d["name"] as? String) ?? "",
            eligible: (d["eligible"] as? Bool) ?? false,
            freeRemaining: (d["freeRemaining"] as? Int) ?? 0,
            studentIDSVG: (d["studentSVG"] as? String) ?? "",
            tickets: tickets)
    }

    // MARK: Injected JS

    /// Classifies the account page: `signedOut` only when the login form is
    /// present, `signedIn` only with a positive account marker, else `unknown`
    /// (challenge/interstitial) so we never wipe cached tickets on a bad read.
    private static let readAccountJS = """
    (() => {
      const q = (s, r=document) => r.querySelector(s);
      if (q('.woocommerce-form-login')) return {state:'signedOut'};
      const card = q('.ucb-student-id');
      const accountMarker = card || q('.woocommerce-MyAccount-navigation') || q('.woocommerce-MyAccount-content');
      if (!accountMarker) return {state:'unknown'};
      const idSvg = card ? (q('svg.qr-svg', card)?.outerHTML || q('svg', card)?.outerHTML || '') : '';
      const name = card?.getAttribute('data-name') || '';
      const bodyText = (q('.woocommerce-MyAccount-content')?.innerText || document.body.innerText || '');
      const eligible = /enrolled/i.test(bodyText);
      const m = bodyText.match(/(\\d+)\\s+of\\s+(\\d+)\\s+free/i);
      const freeRemaining = m ? parseInt(m[1], 10) : (eligible ? 2 : 0);
      // Reserved cards, verified against the live DOM (2026-08-13):
      //   .ucb-student-claim-item[data-order]           the card
      //     .ucb-ticket__header-title                   "THE PROPHECY"
      //     .ucb-ticket__header-meta                    "FRI AUGUST 14, 2026 · 7:00 PM · NY - 14TH ST. MAINSTAGE"
      //     svg.qr-svg.qrcode                           inline QR (path-drawn), present without expanding VIEW TICKET
      //     button.ucb-student-release[data-order][data-nonce]
      const MONTHS = {JAN:1,FEB:2,MAR:3,APR:4,MAY:5,JUN:6,JUL:7,AUG:8,SEP:9,OCT:10,NOV:11,DEC:12};
      const parseStart = line => {
        const dm = line.match(/\\b(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\\.?\\s+(\\d{1,2}),?\\s*(\\d{4})/i);
        const tm = line.match(/(\\d{1,2}):(\\d{2})\\s*(AM|PM)/i);
        if (!dm || !tm) return null;
        let h = parseInt(tm[1], 10) % 12;
        if (/pm/i.test(tm[3])) h += 12;
        const p2 = n => String(n).padStart(2, '0');
        return `${dm[3]}-${p2(MONTHS[dm[1].slice(0,3).toUpperCase()])}-${p2(dm[2])}T${p2(h)}:${tm[2]}:00`;
      };
      const tickets = [];
      const seen = new Set();
      const pushTicket = (order, nonce, svg, title, metaLine) => {
        if (!order || seen.has(order)) return;
        seen.add(order);
        const parts = metaLine.split('·').map(s => s.trim());
        tickets.push({
          order, nonce, event: null,
          title: title || 'UCB show',
          venue: parts[2] || '',
          start: parseStart(metaLine),
          source: /\\bLA\\b|FRANKLIN|LOS ANGELES/i.test(metaLine) ? 'ucb_la' : 'ucb_ny',
          svg
        });
      };
      document.querySelectorAll('.ucb-student-claim-item[data-order]').forEach(item => {
        pushTicket(
          item.getAttribute('data-order'),
          item.querySelector('[data-nonce]')?.getAttribute('data-nonce') || null,
          item.querySelector('svg.qr-svg')?.outerHTML || '',
          (item.querySelector('.ucb-ticket__header-title')?.innerText || '').trim(),
          (item.querySelector('.ucb-ticket__header-meta')?.innerText || '').trim());
      });
      // Fallback if UCB renames the card class: anchor on the release control.
      if (!tickets.length) {
        document.querySelectorAll('.ucb-student-release[data-order], [data-order][data-nonce]').forEach(rel => {
          const scope = rel.closest('[data-order]')?.parentElement?.closest('div, li, article') || rel.parentElement || document;
          if (/cancell?ed|released/i.test(scope.innerText || '')) return;
          pushTicket(
            rel.getAttribute('data-order'),
            rel.getAttribute('data-nonce'),
            scope.querySelector('svg.qr-svg')?.outerHTML || '',
            (scope.querySelector('[class*="title"], h1, h2, h3, h4')?.innerText || '').trim(),
            (scope.querySelector('[class*="meta"], [class*="when"]')?.innerText || scope.innerText || '').trim());
        });
      }
      return {state:'signedIn', name, eligible, freeRemaining, studentSVG:idSvg, tickets};
    })()
    """

    private static let readClaimJS = """
    (() => {
      const b = document.querySelector('.ucb-student-claim[data-event]');
      const confirmed = /student ticket is confirmed|it.s in your account/i.test(document.body.innerText||'');
      return {available: !!b, alreadyClaimed: confirmed, event: b?.dataset.event || null, nonce: b?.dataset.nonce || null};
    })()
    """
}

/// One-shot navigation gate: resolves when the current load finishes, fails, or
/// the caller cancels it (timeout). Every terminal path resumes the continuation
/// exactly once, so `load()` can never hang.
private final class NavGate: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Error>?
    private var done = false

    func wait() async throws {
        try await withCheckedThrowingContinuation { c in
            if done { c.resume(); return }
            cont = c
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        guard !done else { return }
        done = true
        switch result {
        case .success: cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
        cont = nil
    }
    /// Called by the caller's timeout task.
    func cancel() { finish(.failure(CancellationError())) }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(.success(())) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(.failure(e)) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(.failure(e)) }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { finish(.failure(CancellationError())) }
}
