import SwiftUI
import SafariServices
import WebKit

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
struct WebLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// A link to UCB uses the same website storage as the Tickets tab, including
/// when a class or ticket purchase asks the student to sign in mid-checkout.
struct VenueWebView: View {
    let url: URL
    @Environment(UCBAccountStore.self) private var account
    @Environment(TicketStore.self) private var tickets
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if UCBWebOrigin.isTrusted(url) {
            UCBBrowser(url: url, session: account.session, done: { dismiss() })
                .ignoresSafeArea()
                .onDisappear {
                    Task {
                        if account.isSignedIn { await tickets.sync() }
                        else { await account.restoreOnLaunch() }
                    }
                }
        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil {
            SafariView(url: url).ignoresSafeArea()
        } else {
            NavigationStack {
                ContentUnavailableView("Invalid website link", systemImage: "link")
                    .toolbar { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        return vc
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct UCBBrowser: UIViewControllerRepresentable {
    let url: URL
    let session: UCBSession
    let done: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let page = UCBBrowserPage(web: session.makeAccountBrowserWebView(), initialURL: url, done: done)
        let container = UINavigationController(rootViewController: page)
        container.setToolbarHidden(false, animated: false)
        page.loadViewIfNeeded()
        page.web.load(URLRequest(url: url))
        return container
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// Each popup owns the web view that WebKit creates for that window. Checkout
/// providers can keep their opener, post form data and close the window normally.
private final class UCBBrowserPage: UIViewController, WKUIDelegate, WKNavigationDelegate {
    let web: WKWebView
    private let initialURL: URL?
    private let done: () -> Void
    private var observations: [NSKeyValueObservation] = []
    private lazy var back = button("chevron.backward", "Back", #selector(goBack))
    private lazy var forward = button("chevron.forward", "Forward", #selector(goForward))
    private lazy var external = button("safari", "Open in browser", #selector(openExternally))

    init(web: WKWebView, initialURL: URL?, done: @escaping () -> Void) {
        self.web = web
        self.initialURL = initialURL
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() { view = web }

    override func viewDidLoad() {
        super.viewDidLoad()
        web.uiDelegate = self
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.done() })
        navigationItem.rightBarButtonItem = external
        toolbarItems = [back, .flexibleSpace(), forward, .flexibleSpace(),
                        button("arrow.clockwise", "Reload", #selector(reloadPage))]
        observations = [
            web.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in self?.updateControls() },
            web.observe(\.canGoBack) { [weak self] _, _ in self?.updateControls() },
            web.observe(\.canGoForward) { [weak self] _, _ in self?.updateControls() }
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateControls()
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.accessibilityLabel = label
        return item
    }

    private func updateControls() {
        let url = web.url ?? initialURL
        navigationItem.title = url?.host()
        back.isEnabled = web.canGoBack || navigationController?.viewControllers.first !== self
        forward.isEnabled = web.canGoForward
        external.isEnabled = ["https", "http"].contains(url?.scheme?.lowercased() ?? "")
    }

    @objc private func goBack() {
        if web.canGoBack { web.goBack() }
        else { navigationController?.popViewController(animated: true) }
    }
    @objc private func goForward() { web.goForward() }
    @objc private func reloadPage() {
        if web.url != nil { web.reload() }
        else if let initialURL { web.load(URLRequest(url: initialURL)) }
    }
    @objc private func openExternally() {
        if external.isEnabled, let url = web.url ?? initialURL { UIApplication.shared.open(url) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let navigationController else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration)
        let page = UCBBrowserPage(web: child, initialURL: navigationAction.request.url, done: done)
        page.loadViewIfNeeded()
        navigationController.pushViewController(page, animated: true)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let navigationController, navigationController.viewControllers.first !== self else { return }
        navigationController.setViewControllers(navigationController.viewControllers.filter { $0 !== self },
                                                animated: navigationController.topViewController === self)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationItem.prompt = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled else { return }
        navigationItem.prompt = "Couldn’t load this page."
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["tel", "sms", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        } else {
            decisionHandler(.allow)
        }
    }
}

/// Gives an empty result screen the same pull-to-refresh gesture as its list.
struct ScrollablePlaceholder<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content().frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.always)
        }
    }
}

/// Pinned date section header for the feed.
struct SectionHeaderView: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 8)
            .background(.bar)
    }
}

/// Filter toolbar icon with a small count badge when filters are active, so a
/// short list is visibly explained by "2 filters" rather than just a filled icon.
struct FilterToolbarIcon: View {
    let activeCount: Int

    var body: some View {
        Image(systemName: activeCount > 0
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle")
            .overlay(alignment: .topTrailing) {
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 10, y: -8)
                }
            }
            .accessibilityLabel(activeCount > 0 ? "Filters, \(activeCount) active" : "Filters")
    }
}

/// Unobtrusive banner shown when displaying cached data after a failed refresh.
/// `noun` names what's saved — "shows" on the feed, "classes" on the Classes tab.
struct OfflineBanner: View {
    let updatedLabel: String?
    var noun = "shows"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text(bannerText).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal, Theme.Space.gutter)
    }

    private var bannerText: String {
        if let updatedLabel { return "Showing saved \(noun) · \(updatedLabel.lowercased())" }
        return "Showing saved \(noun)"
    }
}
