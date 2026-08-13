import SwiftUI
import WebKit

/// Sign-in sheet: UCB's real `/my-account/` login inside a WebView that shares
/// the session's persistent data store, so Cloudflare Turnstile passes normally
/// and the resulting cookies stay for native reuse. We watch for the logged-in
/// dashboard and hand back — we never see or handle the password.
struct UCBSignInView: View {
    let account: UCBAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            UCBLoginWebView(dataStore: account.session.dataStore) {
                guard !signingIn else { return }
                signingIn = true
                Task {
                    await account.completeSignIn()
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if signingIn {
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

private struct UCBLoginWebView: UIViewRepresentable {
    let dataStore: WKWebsiteDataStore
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: UCBSession.accountURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        private var fired = false
        init(onSignedIn: @escaping () -> Void) { self.onSignedIn = onSignedIn }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            // Signed in once the account pages stop showing the login form.
            let js = "(!document.querySelector('.woocommerce-form-login') && /\\/my-account/.test(location.pathname))"
            web.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.fired, (result as? Bool) == true else { return }
                self.fired = true
                self.onSignedIn()
            }
        }
    }
}
