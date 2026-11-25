import Foundation
import WebKit

/// Exercise the shipping navigation gate and classifier inside WebKit. Simulated
/// responses keep these checks offline and give each test its own cookie store.
@MainActor
func testUCBSessionRefresh() async throws {
    typealias Page = (status: Int, html: String)
    let login = """
        <main><form class="woocommerce-form-login"><input name="username"><input type="password"></form></main>
        """
    let tickets = """
        <main><div class="ucb-id-card--student" data-name="Test Student"><svg></svg></div>
        <div class="ucb-student-panel" data-panel="upcoming"></div></main>
        """
    var pages: [Page] = []
    var requests: [URLRequest] = []
    let jar = WKWebsiteDataStore.nonPersistent()
    let engine = UCBSession(dataStore: jar) { web, request in
        requests.append(request)
        precondition(!pages.isEmpty, "An unexpected account navigation started")
        let page = pages.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: page.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        // Simulated requests omit the main-frame policy callback that an
        // HTTP load delivers. Supply that response before WebKit renders.
        (web.navigationDelegate as! UCBNavigationGate).receivedMainResponse(response)
        return web.loadSimulatedRequest(request, response: response, responseData: Data(page.html.utf8))
    }

    func expect(_ result: Bool, _ message: String) {
        precondition(result, message)
    }

    pages = [(200, tickets)]
    guard case .signedIn(let snapshot) = await engine.refresh() else { preconditionFailure("missed student wallet") }
    expect(snapshot.name == "Test Student", "missing student identity")
    expect(requests.map(\.url) == [UCBSession.studentTicketsURL], "signed-in read should use one request")

    requests.removeAll()
    pages = [(200, login), (200, tickets)]
    guard case .unknown = await engine.refresh() else { preconditionFailure("a stale login page signed the user out") }
    expect(requests.map(\.url) == [UCBSession.studentTicketsURL, UCBSession.accountURL], "expected independent confirmation")
    expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData }, "cached pages must not confirm logout")

    pages = [(200, login), (200, login)]
    guard case .signedOut = await engine.refresh() else { preconditionFailure("missed confirmed session expiry") }

    for page in [(503, login), (202, login), (200, "<main>Please wait</main>")] {
        pages = [page]
        guard case .unknown = await engine.refresh() else { preconditionFailure("an inconclusive response changed identity") }
    }

    // Simulate signing in on an event/registration sheet with a synthetic
    // cookie. The account engine and another sheet must use the very same jar.
    let browser = engine.makeAccountBrowserWebView()
    expect(browser.configuration.websiteDataStore === jar, "browser did not share account data")
    let cookie = HTTPCookie(properties: [.name: "wordpress_logged_in_test", .value: "fixture", .domain: "ucbcomedy.com",
                                         .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
    await browser.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    let remembered = await engine.hasLoginCookie()
    expect(remembered, "engine did not find a login made in a UCB sheet")
    await engine.signOut()
    let afterLogout = await engine.hasLoginCookie()
    expect(!afterLogout, "explicit sign-out left a UCB login cookie")
}
