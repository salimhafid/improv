import SwiftUI
import WebKit

/// Sign-in sheet: UCB's real `/my-account/` login hosted in the SESSION's own
/// web view — so Cloudflare Turnstile passes normally and the resulting cookies
/// are already in the exact web view every later API call uses (no cross-instance
/// sync lag, so the login persists app-wide immediately). We watch for the
/// logged-in dashboard and hand back — we never see or handle the password.
struct UCBSignInView: View {
    let account: UCBAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            UCBLoginWebView(web: account.session.web) {
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
    let web: WKWebView
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
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
            // Signed in once an account page stops showing the login form.
            let js = "(!document.querySelector('.woocommerce-form-login') && /\\/my-account/.test(location.pathname))"
            web.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.fired, (result as? Bool) == true else { return }
                self.fired = true
                self.onSignedIn()
            }
        }
    }
}
