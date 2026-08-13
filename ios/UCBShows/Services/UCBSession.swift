import Foundation
import WebKit

/// The app's UCB "session engine." UCB has no API and sits behind Cloudflare
/// Turnstile + JA3 binding, so credentials can't be POSTed natively and cookies
/// can't be lifted into URLSession. Instead one persistent `WKWebView` (backed
/// by a named, on-device data store) is BOTH the login surface and the API
/// client: the user signs in inside it once, and every authenticated call runs
/// *inside* the web view via injected `fetch()` / DOM reads — so requests carry
/// the real cookies and TLS fingerprint. Nothing hits a server we run.
@MainActor
final class UCBSession {
    static let accountURL = URL(string: "https://ucbcomedy.com/my-account/")!
    static let studentTicketsURL = URL(string: "https://ucbcomedy.com/my-account/student-tickets/")!

    /// Stable identifier so the cookie jar (cf_clearance + WordPress login)
    /// persists across launches.
    private static let storeID = UUID(uuidString: "B9F4C1A2-7E33-49D0-8C21-000000000001")!

    let dataStore: WKWebsiteDataStore = .init(forIdentifier: storeID)

    /// Offscreen web view reused for authenticated reads/writes.
    private lazy var web: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 900), configuration: cfg)
        return w
    }()

    private var navDelegate: NavGate?

    // MARK: Snapshots

    struct AccountSnapshot {
        var name: String
        var eligible: Bool
        var freeRemaining: Int
        var studentIDSVG: String
        var tickets: [Ticket]        // reserved, upcoming
    }

    struct ClaimAvailability {
        var available: Bool
        var alreadyClaimed: Bool
        var event: String?
        var nonce: String?
    }

    struct ActionResult {
        var success: Bool
        var message: String
    }

    // MARK: Navigation + JS plumbing

    private func load(_ url: URL) async throws {
        let gate = NavGate()
        navDelegate = gate
        web.navigationDelegate = gate
        web.load(URLRequest(url: url))
        try await gate.wait()
    }

    @discardableResult
    private func eval(_ js: String) async throws -> Any? {
        try await web.evaluateJavaScript(js)
    }

    private func loadAndRead(_ url: URL, _ js: String) async throws -> Any? {
        try await load(url)
        // Give client-rendered bits (QR SVG) a beat to paint.
        try? await Task.sleep(for: .milliseconds(250))
        return try await eval(js)
    }

    // MARK: Public API

    /// Read the student-tickets page. Returns nil when not signed in (the page
    /// falls back to the WooCommerce login form).
    func refresh() async -> AccountSnapshot? {
        guard let raw = try? await loadAndRead(Self.studentTicketsURL, Self.readAccountJS),
              let dict = raw as? [String: Any],
              (dict["signedIn"] as? Bool) == true
        else { return nil }
        return Self.parseSnapshot(dict)
    }

    /// Check a show page for a student claim control.
    func claimAvailability(showURL: URL) async -> ClaimAvailability {
        guard let raw = try? await loadAndRead(showURL, Self.readClaimJS),
              let d = raw as? [String: Any] else {
            return ClaimAvailability(available: false, alreadyClaimed: false, event: nil, nonce: nil)
        }
        return ClaimAvailability(
            available: (d["available"] as? Bool) ?? false,
            alreadyClaimed: (d["alreadyClaimed"] as? Bool) ?? false,
            event: d["event"] as? String, nonce: d["nonce"] as? String)
    }

    /// Fire the reserve (must already be on a page of the ucbcomedy.com origin,
    /// which `claimAvailability` leaves us on).
    func claim(event: String, nonce: String) async -> ActionResult {
        await post(action: "ucb_student_claim", params: ["event": event, "nonce": nonce])
    }

    func release(order: String, nonce: String) async -> ActionResult {
        await post(action: "ucb_student_release", params: ["order": order, "nonce": nonce])
    }

    /// Sign out: drop the entire cookie jar for this store.
    func signOut() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    // MARK: admin-ajax POST (executed inside the web view)

    private func post(action: String, params: [String: String]) async -> ActionResult {
        var body = "action=\(action)"
        for (k, v) in params {
            body += "&\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)"
        }
        let js = """
        (async () => {
          try {
            const r = await fetch('https://ucbcomedy.com/wp-admin/admin-ajax.php', {
              method:'POST', credentials:'same-origin',
              headers:{'Content-Type':'application/x-www-form-urlencoded'},
              body: \(jsString(body))
            });
            const j = await r.json();
            return JSON.stringify({ok: !!j.success, msg: (j.data && j.data.message) || ''});
          } catch(e) { return JSON.stringify({ok:false, msg:'Network error'}); }
        })()
        """
        guard let raw = try? await eval(js) as? String,
              let data = raw.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ActionResult(success: false, message: "Something went wrong. Please try again.") }
        return ActionResult(success: (d["ok"] as? Bool) ?? false, message: (d["msg"] as? String) ?? "")
    }

    private func jsString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s], options: []), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "''"
    }

    // MARK: Parsing

    private static func parseSnapshot(_ d: [String: Any]) -> AccountSnapshot {
        var tickets: [Ticket] = []
        for t in (d["tickets"] as? [[String: Any]]) ?? [] {
            let order = t["order"] as? String
            tickets.append(Ticket(
                kind: .reserved,
                showID: nil,
                orderID: order,
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

    /// Reads the student-tickets page into a plain object. Defensive selectors:
    /// the release button (data-order/data-nonce) is the anchor for each
    /// reserved card, since the release controller keys off exactly those.
    private static let readAccountJS = """
    (() => {
      const q = (s, r=document) => r.querySelector(s);
      const loginForm = q('.woocommerce-form-login');
      if (loginForm) return {signedIn:false};
      const card = q('.ucb-student-id');
      const idSvg = card ? (q('.ucb-ticket__qr', card)?.outerHTML || q('svg', card)?.outerHTML || '') : '';
      const name = card?.getAttribute('data-name') || '';
      // eligibility + remaining count
      const bodyText = (q('.woocommerce-MyAccount-content')?.innerText || document.body.innerText || '');
      const eligible = /enrolled/i.test(bodyText);
      const m = bodyText.match(/(\\d+)\\s+of\\s+(\\d+)\\s+free/i);
      const freeRemaining = m ? parseInt(m[1], 10) : (eligible ? 2 : 0);
      // reserved tickets: one per release button
      const tickets = [];
      document.querySelectorAll('[data-order][data-nonce]').forEach(rel => {
        const cardEl = rel.closest('li, .ucb-ticket, article, .ticket, div');
        const scope = cardEl || document;
        const svg = (scope.querySelector('.ucb-ticket__qr')?.outerHTML) || (scope.querySelector('svg')?.outerHTML) || '';
        const title = (scope.querySelector('h1,h2,h3,h4,.ucb-ticket__title')?.innerText || '').trim();
        const meta = (scope.innerText || '');
        const stMatch = meta.match(/ST-(\\d+)/);
        const source = /\\bLA\\b|Franklin|Los Angeles/i.test(meta) ? 'ucb_la' : 'ucb_ny';
        tickets.push({
          order: rel.getAttribute('data-order'),
          nonce: rel.getAttribute('data-nonce'),
          event: stMatch ? stMatch[1] : null,
          title: title || 'UCB show',
          venue: (meta.match(/NY[^\\n]*Mainstage|LA[^\\n]*|[0-9]+th St[^\\n]*/i)||[''])[0].trim(),
          svg
        });
      });
      return {signedIn:true, name, eligible, freeRemaining, studentSVG:idSvg, tickets};
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

/// One-shot navigation gate: resolves when the current load finishes (or fails).
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
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(.success(())) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(.failure(e)) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(.failure(e)) }
}
