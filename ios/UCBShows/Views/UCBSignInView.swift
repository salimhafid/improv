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
    @Environment(\.dismiss) private var dismiss
    @State private var verification: Task<Void, Never>?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            UCBLoginWebView(
                session: account.session,
                onLoaded: { loading = false },
                onSignedIn: { web in
                    guard verification == nil else { return }
                    account.session.endLogin()
                    verification = Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        let outcome = await account.completeSignIn()
                        guard !Task.isCancelled, web.navigationDelegate != nil else { return }
                        verification = nil
                        if case .signedOut = outcome {
                            // UCB returned a real login form. Present the
                            // current account page so the user can sign in again.
                            account.session.beginLogin()
                            loading = true
                            web.load(URLRequest(url: UCBSession.accountURL,
                                                cachePolicy: .reloadIgnoringLocalCacheData))
                        } else {
                            dismiss()
                        }
                    }
                })
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if loading {
                        ProgressView("Loading UCB…")
                    } else if verification != nil {
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
                        Button("Cancel") { verification?.cancel(); dismiss() }
                    }
                }
        }
        .onDisappear {
            verification?.cancel()
            verification = nil
        }
    }
}

/// Plain, standard WKWebView hosting: the representable creates the view, owns
/// it for exactly the sheet's lifetime, and lets it be discarded with the sheet.
private struct UCBLoginWebView: UIViewRepresentable {
    let session: UCBSession
    let onLoaded: () -> Void
    let onSignedIn: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded, onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.session = session
        session.beginLogin()                       // engine ops stand down
        let web = session.makeAccountBrowserWebView()
        web.navigationDelegate = context.coordinator
        let controller = web.configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: UCBSession.dashboardMessage)
        controller.addUserScript(WKUserScript(source: UCBSession.observeDashboardJS,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                              in: .defaultClient))
        web.load(URLRequest(url: UCBSession.accountURL, cachePolicy: .reloadIgnoringLocalCacheData))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(
            forName: UCBSession.dashboardMessage, contentWorld: .defaultClient)
        web.stopLoading()
        coordinator.session?.endLogin()
        coordinator.session = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onLoaded: () -> Void
        let onSignedIn: (WKWebView) -> Void
        weak var session: UCBSession?
        private var navigationGeneration = 0

        init(onLoaded: @escaping () -> Void, onSignedIn: @escaping (WKWebView) -> Void) {
            self.onLoaded = onLoaded
            self.onSignedIn = onSignedIn
        }

        func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navigationGeneration += 1
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let web = message.webView, session != nil,
                  UCBWebOrigin.isTrusted(message.frameInfo.request.url),
                  UCBWebOrigin.isTrusted(web.url) else { return }
            let generation = navigationGeneration
            // A message may have been enqueued by the page we just left.
            web.evaluateJavaScript(UCBSession.accountPageStateJS, in: nil, in: .defaultClient) { [weak self, weak web] result in
                guard let self, let web, self.session != nil, self.navigationGeneration == generation,
                      case .success(let state) = result, state as? String == "signedIn" else { return }
                self.onSignedIn(web)
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
