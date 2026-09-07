import SwiftUI
import WebKit

/// Sign-in sheet: UCB's real `/my-account/` login in a web view that shares the
/// session engine's cookie jar (same `WKWebsiteDataStore` → same network
/// process), so Cloudflare Turnstile passes normally and the login is visible
/// to every later API call immediately. The sheet's web view is created fresh
/// each time and torn down with the sheet — it is never the engine's off-screen
/// web view, so no view is ever moved between windows (the pattern that crashes
/// UIKit's delayed-touch bookkeeping mid-gesture). While the sheet is up,
/// off-screen ops stand down (`beginLogin`/`endLogin`). We watch for the
/// logged-in dashboard and hand back — we never see or handle the password.
struct UCBSignInView: View {
    let account: UCBAccountStore
    @Environment(TicketStore.self) private var tickets
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false
    @State private var loading = true

    var body: some View {
        NavigationStack {
            UCBLoginWebView(
                session: account.session,
                onLoaded: { loading = false },
                onSignedIn: {
                    guard !signingIn else { return }
                    signingIn = true
                    Task {
                        account.session.endLogin()
                        // One read feeds both the account and the wallet, as
                        // launch does — otherwise the Tickets tab pays for a
                        // second serialized navigation the moment it appears.
                        let outcome = await account.completeSignIn()
                        tickets.adopt(outcome)
                        if case .signedOut = outcome {
                            // The dashboard we saw didn't hold up as a login
                            // (cookie didn't stick, page misread). Dismissing
                            // here would drop the user on a wallet that says
                            // "connect", with no idea why — stay, and let the
                            // next dashboard load try again.
                            account.session.beginLogin()   // sheet still owns the web view
                            signingIn = false
                        } else {
                            dismiss()
                        }
                    }
                })
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if loading {
                        ProgressView("Loading UCB…")
                    } else if signingIn {
                        ZStack {
                            Color(.systemBackground).opacity(0.7).ignoresSafeArea()
                            ProgressView("Signing in…")
                        }
                    }
                }
                .navigationTitle("Sign in to UCB")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

/// Plain, standard WKWebView hosting: the representable creates the view, owns
/// it for exactly the sheet's lifetime, and lets it be discarded with the sheet.
private struct UCBLoginWebView: UIViewRepresentable {
    let session: UCBSession
    let onLoaded: () -> Void
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded, onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.session = session
        session.beginLogin()                       // engine ops stand down
        let web = session.makeLoginWebView()
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: UCBSession.accountURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    // Always release the engine's login claim when the sheet goes away
    // (cancel or done). The web view itself just gets discarded.
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        coordinator.session?.endLogin()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void
        let onSignedIn: () -> Void
        weak var session: UCBSession?
        init(onLoaded: @escaping () -> Void, onSignedIn: @escaping () -> Void) {
            self.onLoaded = onLoaded
            self.onSignedIn = onSignedIn
        }

        /// Signed in = a POSITIVE dashboard marker (the account navigation or
        /// the Student ID card), the same classifier the engine's
        /// `readAccountJS` uses. "No login form on a /my-account/ page" is not
        /// enough: the lost-password page and a Cloudflare interstitial both
        /// satisfy it, and firing there closed the sheet mid-reset (or marked a
        /// user who never logged in as signed in). Repeats are deduped by the
        /// view's `signingIn`, so a load that didn't hold up can fire again.
        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded()
            let js = """
            (!document.querySelector('.woocommerce-form-login')
             && /\\/my-account/.test(location.pathname)
             && !!(document.querySelector('.woocommerce-MyAccount-navigation')
                   || document.querySelector('.ucb-student-id')))
            """
            web.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, (result as? Bool) == true else { return }
                self.onSignedIn()
            }
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoaded()
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoaded()
        }
    }
}
