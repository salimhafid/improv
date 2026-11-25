import AppKit
import WebKit

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private final class AccountPageFixture: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    private(set) var dashboardMessages = 0

    init(session: UCBSession) {
        web = session.makeAccountBrowserWebView()
        super.init()
        let scripts = web.configuration.userContentController
        scripts.add(self, contentWorld: .defaultClient, name: UCBSession.dashboardMessage)
        scripts.addUserScript(WKUserScript(source: UCBSession.observeDashboardJS, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        dashboardMessages += 1
    }

    func load(_ html: String, at url: String = "https://ucbcomedy.com/my-account/") async throws {
        let documentID = UUID().uuidString
        web.loadHTMLString("<!doctype html><html id='\(documentID)'><body>\(html)</body></html>",
                           baseURL: URL(string: url)!)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let ready = try? await web.evaluateJavaScript("document.documentElement.id === '\(documentID)' && document.readyState === 'complete'")
            if ready as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw FixtureFailure("Offline WKWebView failed to load \(url)")
    }

    func expect(_ expression: String, _ message: String) async throws {
        let value = try await web.evaluateJavaScript(expression)
        guard value as? Bool == true else { throw FixtureFailure(message) }
    }

    func stateIs(_ state: String, _ message: String) async throws {
        let value = try await web.evaluateJavaScript(UCBSession.accountPageStateJS)
        guard value as? String == state else { throw FixtureFailure("\(message): expected \(state), got \(String(describing: value))") }
    }
}

@main
enum AccountWebKitTests {
    /// Run the real named WebKit store across separate app processes. The
    /// parent owns the randomly created test store and removes it after exit.
    @MainActor
    private static func testColdLaunchCookie() async throws {
        // The process calling WebKit's store-removal API needs its own WebKit
        // run loop. Under the macOS CLI, initializing WebKit only in the child
        // processes leaves its cleanup callback with no run loop to dispatch to.
        let cleanupConfig = WKWebViewConfiguration()
        cleanupConfig.websiteDataStore = .nonPersistent()
        let cleanupWebView = WKWebView(frame: .zero, configuration: cleanupConfig)
        _ = try await cleanupWebView.evaluateJavaScript("true")
        let id = UUID()
        do {
            for phase in ["write", "restore-and-sign-out", "verify-signed-out"] {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--cookie-fixture", id.uuidString, phase]
                try child.run()
                child.waitUntilExit()
                if child.terminationStatus != 0 { throw FixtureFailure("WebKit cookie fixture failed in phase \(phase)") }
            }
        } catch {
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
            throw error
        }
        try await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    @MainActor
    private static func runCookieFixture(_ id: UUID, phase: String) async throws {
        let store = WKWebsiteDataStore(forIdentifier: id)
        let session = UCBSession(dataStore: store)
        switch phase {
        case "write":
            guard !(await session.hasLoginCookie()) else { throw FixtureFailure("Expected a new fixture store") }
            let cookie = HTTPCookie(properties: [
                .domain: "ucbcomedy.com", .path: "/", .name: "wordpress_logged_in_fixture", .value: "offline",
                .secure: "TRUE", .expires: Date().addingTimeInterval(3600)
            ])!
            let login = session.makeAccountBrowserWebView()
            await login.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            guard await session.hasLoginCookie() else { throw FixtureFailure("Remembered cookie was not written") }
        case "restore-and-sign-out":
            guard await session.hasLoginCookie() else { throw FixtureFailure("Relaunch lost the remembered cookie") }
            await session.signOut()
        case "verify-signed-out":
            guard !(await session.hasLoginCookie()) else { throw FixtureFailure("Sign-out did not survive relaunch") }
        default:
            throw FixtureFailure("Unknown WebKit cookie fixture phase")
        }
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--cookie-fixture", let id = UUID(uuidString: args[2]) {
            try await runCookieFixture(id, phase: args[3])
            print("Cold-launch WebKit cookie check passed: \(args[3])")
            return
        }
        UCBWebOriginTests.run()
        try await testColdLaunchCookie()
        let session = UCBSession(dataStore: .nonPersistent())
        let page = AccountPageFixture(session: session)
        let login = """
            <form class="woocommerce-form woocommerce-form-login login">
              <input name="username"><input type="password" name="password">
              <input type="checkbox" name="rememberme" id="rememberme">
            </form>
            """
        let dashboard = """
            <nav class="woocommerce-MyAccount-navigation"><a href="/my-account/account-settings/">Settings</a></nav>
            """
        let card = "<div class='ucb-id-card--student' data-name='Sample student'><svg></svg></div>"

        try await page.load("<main>\(login)</main>")
        try await page.stateIs("signedOut", "The genuine login form is definitive")
        try await page.expect("document.querySelector('#rememberme').checked", "UCB login should default to Remember Me")
        _ = try await page.web.evaluateJavaScript("""
            document.querySelector('#rememberme').click();
            document.querySelector('main').innerHTML = document.querySelector('main').innerHTML;
            """)
        try await page.expect("!document.querySelector('#rememberme').checked", "User opt-out must survive form replacement")

        try await page.load("<header>\(login)</header><main><div hidden>\(login)</div>\(card)</main>")
        try await page.stateIs("signedIn", "The new student card wins over unrelated hidden login forms")
        try await page.load("<main><div class='ucb-student-id'><svg></svg></div></main>")
        try await page.stateIs("signedIn", "The old populated student card still works")
        try await page.load("<main>\(dashboard)</main>")
        try await page.stateIs("signedIn", "Authenticated account navigation identifies non-students")
        try await page.load("<style>.collapsed{display:none}</style><main><div class='collapsed'>\(login)</div></main>")
        try await page.stateIs("unknown", "A hidden login form cannot sign someone out")
        try await page.load("<main><form class='woocommerce-form-login'><div hidden><input name='username'><input type='password'></div></form></main>")
        try await page.stateIs("unknown", "A collapsed credential prompt cannot sign someone out")
        try await page.load("<main><div class='woocommerce-MyAccount-content'>Loading…</div><nav class='woocommerce-MyAccount-navigation'></nav><div class='ucb-id-card--student'></div></main>")
        try await page.stateIs("unknown", "Unpopulated private-page containers are inconclusive")

        let previousCount = page.dashboardMessages
        _ = try await page.web.evaluateJavaScript("""
            const card = document.querySelector('.ucb-id-card--student');
            card.dataset.name = 'Sample student';
            """)
        let deadline = ContinuousClock.now + .seconds(3)
        while page.dashboardMessages == previousCount, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        guard page.dashboardMessages == previousCount + 1 else {
            throw FixtureFailure("The login sheet must recognize a dashboard populated after navigation")
        }

        try await page.load("<main>\(login)\(dashboard)</main>")
        try await page.stateIs("unknown", "A contradictory public/private page should retain the session")
        for url in ["https://ucbcomedy.com/my-account/lost-password/", "https://ucbcomedy.com/my-account-lookalike/",
                    "http://ucbcomedy.com/my-account/", "https://ucbcomedy.com.example/my-account/",
                    "https://ucbcomedy.com:444/my-account/", "https://ucbcomedy.com/event/show/"] {
            try await page.load("<main>\(dashboard)</main>", at: url)
            try await page.stateIs("unknown", "A page outside the private UCB account cannot complete login (\(url))")
        }
        try await page.load("<main>\(login)</main>", at: "https://example.org/checkout/")
        try await page.expect("!document.querySelector('#rememberme').checked", "Third-party login preferences must be untouched")
        try await page.load("<main>\(login)</main>", at: "https://www.ucbcomedy.com/checkout/")
        try await page.expect("document.querySelector('#rememberme').checked", "Recognize a WooCommerce login in UCB checkout")

        try await testUCBSessionRefresh()
        print("UCB account WebKit tests passed")
    }
}
