import Foundation
import WebKit

/// The login sheet, UCB checkout and private account reads use one persistent
/// WebKit data store. UCB owns all session cookies and their expiration.
/// The off-screen web view serializes account reads and ticket operations.
@MainActor
final class UCBSession {
    static let accountURL = URL(string: "https://ucbcomedy.com/my-account/")!
    static let studentTicketsURL = URL(string: "https://ucbcomedy.com/my-account/student-tickets/")!

    private static let storeID = UUID(uuidString: "B9F4C1A2-7E33-49D0-8C21-000000000001")!
    let dataStore: WKWebsiteDataStore
    private let navigate: @MainActor (WKWebView, URLRequest) -> WKNavigation?

    /// The ENGINE web view: permanently off-screen, never installed in a window,
    /// never touched — it only loads pages and runs injected JS. Keeping it out
    /// of the view hierarchy entirely means UIKit's touch machinery can never
    /// interact with it (moving a live web view in/out of windows mid-gesture
    /// crashes UIKit's delayed-touch bookkeeping).
    let web: WKWebView

    convenience init() {
        self.init(dataStore: .init(forIdentifier: Self.storeID))
    }

    init(dataStore: WKWebsiteDataStore,
         navigate: @escaping @MainActor (WKWebView, URLRequest) -> WKNavigation? = { $0.load($1) }) {
        self.dataStore = dataStore
        self.navigate = navigate
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 900),
                        configuration: Self.configuration(store: dataStore))
    }

    private static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        return cfg
    }

    /// A fresh account or checkout browser over the same persistent data store —
    /// same network process, same cookie jar — so the cookies the user earns by
    /// logging in are immediately visible to the engine's calls. The sheet owns
    /// it outright and it dies with the sheet: never reused, never reparented,
    /// so no gesture state can outlive its window.
    func makeAccountBrowserWebView() -> WKWebView {
        let cfg = Self.configuration(store: dataStore)
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.rememberMeJS, injectionTime: .atDocumentStart,
                         forMainFrameOnly: true, in: .defaultClient))
        return WKWebView(frame: .zero, configuration: cfg)
    }

    private static let isUCBOriginJS = "['https://ucbcomedy.com', 'https://www.ucbcomedy.com'].includes(location.origin)"

    /// Only UCB's HTTPS account pages can establish an app session. The account
    /// recovery pages may also have WooCommerce navigation and login links.
    static let isAccountPageJS = """
    (\(isUCBOriginJS)
      && /^\\/my-account(?:\\/|$)/.test(location.pathname)
      && !/^\\/my-account\\/(?:lost-password|reset-password|register|customer-logout)(?:\\/|$)/.test(location.pathname))
    """

    private static let loginFormSelector = "form.woocommerce-form-login, #customer_login form.login, form:has(input[name=woocommerce-login-nonce])"

    /// The sheet and the engine must agree before changing the on-device
    /// account state. Scope both checks to the account content; headers, drawers
    /// and hidden templates can include a login form on an authenticated page.
    static let accountPageStateJS = """
    (() => {
      if (!\(isAccountPageJS)) return 'unknown';
      const scope = document.querySelector('main, [role="main"], #main') || document;
      const visible = el => {
        if (el.closest('header, footer, [role="banner"], dialog, [role="dialog"], [inert], [hidden], [aria-hidden="true"]')) return false;
        for (let node = el; node; node = node.parentElement) {
          const css = getComputedStyle(node);
          if (css.display === 'none' || css.visibility === 'hidden') return false;
        }
        return true;
      };
      const anyVisible = (selector, check) => Array.from(scope.querySelectorAll(selector))
        .some(el => visible(el) && check(el));
      const hasLogin = anyVisible('\(loginFormSelector)', form => {
        const hasField = selector => Array.from(form.querySelectorAll(selector)).some(visible);
        return hasField('input[type="password"]') && hasField('input[name="username"], input[type="email"], input[autocomplete="username"]');
      });
      const hasCard = anyVisible('.ucb-id-card--student, .ucb-student-id', card =>
        card.getAttribute('data-name') || card.querySelector('svg') || card.textContent.trim());
      const hasAccountLink = anyVisible('.woocommerce-MyAccount-navigation a[href], .woocommerce-MyAccount-content a[href]', link => {
        if (link.origin !== location.origin) return false;
        return /^\\/my-account\\/customer-logout\\/?$/.test(link.pathname)
          || (link.pathname === '/wp-login.php' && new URLSearchParams(link.search).get('action') === 'logout')
          || (link.closest('.woocommerce-MyAccount-navigation') && /^\\/my-account\\/(?:edit-account|account-settings|orders|student-tickets|in-person-tickets)\\/?$/.test(link.pathname));
      });
      if (hasLogin && (hasCard || hasAccountLink)) return 'unknown';
      if (hasCard || hasAccountLink) return 'signedIn';
      return hasLogin ? 'signedOut' : 'unknown';
    })()
    """

    static let dashboardMessage = "ucbAccountReady"
    // UCB can populate the private dashboard after navigation finishes.
    // Observe in WebKit's isolated client world so page scripts and frames
    // cannot invoke the app's completion handler.
    static let observeDashboardJS = """
    (() => {
      if (!\(isAccountPageJS)) return;
      const check = () => {
        if (\(accountPageStateJS) !== 'signedIn') return;
        observer.disconnect();
        window.webkit.messageHandlers.\(dashboardMessage).postMessage(null);
      };
      const observer = new MutationObserver(check);
      observer.observe(document, { childList: true, subtree: true, attributes: true,
        attributeFilter: ['class', 'style', 'hidden', 'aria-hidden', 'data-name', 'href'] });
      check();
    })();
    """


    /// Default UCB's real login checkbox to persistent sign-in. Keep the user's
    /// selection through form replacements and validation redirects in this
    /// sheet. WordPress sets and enforces the eventual server-side expiration.
    static let rememberMeJS = """
    (() => {
      if (!\(isUCBOriginJS) || !/^\\/(?:my-account|checkout)(?:\\/|$)/.test(location.pathname)) return;
      const forms = '\(loginFormSelector)';
      const boxes = 'input[type="checkbox"][name="rememberme"], input[type="checkbox"]#rememberme';
      const seen = new WeakSet();
      const preferenceKey = 'improv.ucb.rememberMe';
      let remember = true;
      try { remember = sessionStorage.getItem(preferenceKey) !== 'false'; } catch {}
      const apply = () => {
        for (const form of document.querySelectorAll(forms)) {
          if (form.closest('header, footer, dialog, [role="banner"], [role="dialog"]')) continue;
          for (const box of form.querySelectorAll(boxes)) {
            if (seen.has(box)) continue;
            seen.add(box);
            box.checked = remember;
            box.addEventListener('change', () => {
              remember = box.checked;
              try { sessionStorage.setItem(preferenceKey, String(remember)); } catch {}
            });
          }
        }
      };
      apply();
      new MutationObserver(apply).observe(document, { childList: true, subtree: true });
    })();
    """

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
    private var loginGeneration = 0

    /// Not cancellation-aware while queued (a waiter's continuation has to be
    /// resumed by `unlock` exactly once), so every op checks `Task.isCancelled`
    /// right after acquiring: a `StudentReserveButton` evaluation that was
    /// cancelled by the next push would otherwise still spend a 1–20 s
    /// navigation of its own before the lock moved on.
    private func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// The sign-in sheet claims the web view: abort any in-flight op load (it
    /// fails out and releases the lock) and make new ops stand down.
    func beginLogin() {
        loginGeneration &+= 1
        loginActive = true
        web.stopLoading()
        availabilityCache.removeAll()
    }
    func endLogin() { loginActive = false }

    // MARK: Bounded navigation + JS

    private static let loadTimeout: Duration = .seconds(20)

    private func load(_ url: URL, freshAccountPage: Bool = false) async throws {
        let g = UCBNavigationGate()
        web.navigationDelegate = g
        // Bind the gate to THIS navigation: a stopped load (timeout, or the
        // sign-in sheet claiming the web view) reports its cancellation
        // asynchronously, and without the binding that late callback could
        // land on the next op's gate and fail a load that never started.
        let policy: URLRequest.CachePolicy = freshAccountPage ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        g.navigation = navigate(web, URLRequest(url: url, cachePolicy: policy))
        let timeout = Task { try? await Task.sleep(for: Self.loadTimeout); g.cancel() }
        defer { timeout.cancel() }
        do { try await g.wait() }
        catch { web.stopLoading(); throw error }
        if freshAccountPage {
            guard let response = g.mainResponse, response.statusCode == 200, UCBWebOrigin.isTrusted(response.url),
                  let finalURL = web.url, UCBWebOrigin.isTrusted(finalURL),
                  response.url?.host == finalURL.host, response.url?.path == finalURL.path else {
                throw URLError(.badServerResponse)
            }
        }
        try await Task.sleep(for: .milliseconds(300))  // let the client-rendered QR SVG paint
    }

    private func evalDict(_ js: String) async -> [String: Any]? {
        (try? await web.evaluateJavaScript(js)) as? [String: Any]
    }

    private var onUCBOrigin: Bool { UCBWebOrigin.isTrusted(web.url) }

    /// A hint to attempt a fresh account read when a device lost its marker.
    /// Cookie values stay in WebKit. UCB's account page decides whether a
    /// session is valid, including when UCB has revoked an unexpired cookie.
    func hasLoginCookie() async -> Bool {
        let cookies = await dataStore.httpCookieStore.allCookies()
        return cookies.contains { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (domain == "ucbcomedy.com" || domain == "www.ucbcomedy.com")
                && cookie.name.hasPrefix("wordpress_logged_in_")
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    // MARK: Public API (each self-contained + serialized)

    func refresh() async -> RefreshOutcome {
        let generation = loginGeneration
        func canRead() -> Bool { !loginActive && generation == loginGeneration && !Task.isCancelled }
        guard canRead() else { return .unknown }
        await lock(); defer { unlock() }
        guard canRead() else { return .unknown }
        availabilityCache.removeAll()
        guard (try? await load(Self.studentTicketsURL, freshAccountPage: true)) != nil, canRead(),
              let data = await evalDict(Self.readAccountJS), canRead() else { return .unknown }
        switch data["state"] as? String {
        case "signedIn":
            // A dashboard redirect proves identity but has no ticket list.
            // Publishing its empty list would erase the user's saved tickets.
            guard web.url?.path == Self.studentTicketsURL.path else { return .unknown }
            return .signedIn(Self.parseSnapshot(data))
        case "signedOut":
            // Confirm independently on a fresh dashboard before deleting the
            // sign-in marker and wallet. A stale login page or a cookie still
            // propagating from the just-completed login must not sign a user out.
            guard (try? await load(Self.accountURL, freshAccountPage: true)) != nil, canRead(),
                  let state = try? await web.evaluateJavaScript(Self.accountPageStateJS) as? String,
                  canRead(), state == "signedOut" else { return .unknown }
            return .signedOut
        default: return .unknown
        }
    }

    func claimAvailability(showURL: URL) async -> ClaimAvailability {
        if let hit = availabilityCache[showURL.absoluteString],
           Date().timeIntervalSince(hit.at) < Self.availabilityTTL { return hit.value }
        if loginActive { return .none }
        await lock(); defer { unlock() }
        if loginActive || Task.isCancelled { return .none }
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
        // Re-checked after the lock: the sheet may have claimed the web view
        // while this op was queued, and a claim POST mid-login is the last
        // thing the user expects.
        if loginActive || Task.isCancelled {
            return ActionResult(success: false, message: "Try again in a moment.")
        }
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
        if loginActive || Task.isCancelled {
            return ActionResult(success: false, message: "Try again in a moment.")
        }
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

    /// The title a reserved card gets when the page didn't yield one (also
    /// the literal in `readAccountJS`). `TicketStore` treats it as "unknown"
    /// and keeps the title it already had, since reminder joins key on title.
    static let fallbackTitle = "UCB show"

    private static func parseSnapshot(_ d: [String: Any]) -> AccountSnapshot {
        var tickets: [Ticket] = []
        for t in (d["tickets"] as? [[String: Any]]) ?? [] {
            tickets.append(Ticket(
                kind: .reserved, showID: nil, orderID: t["order"] as? String,
                eventID: t["event"] as? String,
                title: (t["title"] as? String) ?? fallbackTitle,
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
      const state = \(accountPageStateJS);
      if (state !== 'signedIn') return {state};
      const card = q('.ucb-id-card--student') || q('.ucb-student-id');
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
      // Since the November 2026 redesign the page lists Upcoming, Past and
      // Cancelled tabs with the same card markup; only Upcoming are tickets.
      // Without the tabs (the older page) every card is a current one.
      const cardScope = q('.ucb-student-panel') ? (q('.ucb-student-panel[data-panel="upcoming"]') || document.createElement('div')) : document;
      cardScope.querySelectorAll('.ucb-student-claim-item[data-order]').forEach(item => {
        pushTicket(
          item.getAttribute('data-order'),
          item.querySelector('[data-nonce]')?.getAttribute('data-nonce') || null,
          item.querySelector('svg.qr-svg')?.outerHTML || '',
          (item.querySelector('.ucb-ticket__header-title')?.innerText || '').trim(),
          (item.querySelector('.ucb-ticket__header-meta')?.innerText || '').trim());
      });
      // Fallback if UCB renames the card class: anchor on the release control.
      if (!tickets.length) {
        cardScope.querySelectorAll('.ucb-student-release[data-order], [data-order][data-nonce]').forEach(rel => {
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
      // The claim control: since UCB's November 2026 ticket picker, the
      // "Student Ticket" radio row; before it, a `.ucb-student-claim` button.
      // Both carry data-event / data-nonce for the same ucb_student_claim call.
      const b = document.querySelector('input[data-student-claim][data-event]:not(:disabled), .ucb-student-claim[data-event]');
      const confirmed = /student ticket is confirmed|it.s in your account/i.test(document.body.innerText||'');
      return {available: !!b, alreadyClaimed: confirmed, event: b?.dataset.event || null, nonce: b?.dataset.nonce || null};
    })()
    """
}

/// One-shot navigation gate: resolves when the current load finishes, fails, or
/// the caller cancels it (timeout). Every terminal path resumes the continuation
/// exactly once, so `load()` can never hang. Bound to the `WKNavigation` the
/// caller started (when WebKit handed one back): callbacks for any other
/// navigation — a previous op's stopped load reporting in late — are ignored.
final class UCBNavigationGate: NSObject, WKNavigationDelegate {
    var navigation: WKNavigation?
    private var cont: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private(set) var mainResponse: HTTPURLResponse?

    func receivedMainResponse(_ response: URLResponse) {
        mainResponse = response as? HTTPURLResponse
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            receivedMainResponse(navigationResponse.response)
        }
        decisionHandler(.allow)
    }

    private func owns(_ n: WKNavigation?) -> Bool {
        guard let navigation, let n else { return true }
        return n === navigation
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { c in
            if let result { c.resume(with: result); return }
            cont = c
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        cont?.resume(with: result)
        cont = nil
    }
    /// Called by the caller's timeout task.
    func cancel() { finish(.failure(CancellationError())) }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if owns(n) { finish(.success(())) }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        if owns(n) { finish(.failure(e)) }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        if owns(n) { finish(.failure(e)) }
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { finish(.failure(CancellationError())) }
}
