import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WebKit

/// Renders UCB ticket QR codes. UCB serves each QR as inline vector SVG; we
/// rasterize it ONCE (off-screen WKWebView snapshot) into a cached UIImage that
/// every surface shares — wallet rows, the full-screen ticket, and notification
/// attachments. Static images keep tab switches and scrolling smooth (no live
/// web views in the hierarchy) and can't blank out if WebKit's content process
/// is reclaimed while the app is suspended.
enum QRRender {

    /// One canonical render size for the cache: 960px covers the largest
    /// on-screen use (320pt @3x) and notification attachments alike.
    private static let renderSide: CGFloat = 960

    @MainActor private static var cache: [Int: UIImage] = [:]

    /// The rasterized QR for this SVG, rendered on first request and cached
    /// for the life of the process.
    @MainActor
    static func cachedImage(svg: String) async -> UIImage? {
        guard !svg.isEmpty else { return nil }
        let key = svg.hashValue
        if let hit = cache[key] { return hit }
        guard let image = await rasterizeImage(svg: svg, side: renderSide) else { return nil }
        cache[key] = image
        return image
    }

    /// PNG for notification attachments — same cached render.
    @MainActor
    static func rasterize(svg: String) async -> Data? {
        await cachedImage(svg: svg)?.pngData()
    }

    /// Wrap raw `<svg>…</svg>` markup in a minimal white card so any scanner
    /// sees maximum contrast regardless of the app's theme.
    private static func html(for svg: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#fff}
        .wrap{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:6%}
        .wrap svg{width:100%;height:100%;display:block}</style></head>
        <body><div class="wrap">\(svg)</div></body></html>
        """
    }

    /// Rasterize QR SVG markup to a square image via a throwaway off-screen
    /// web view. Bounded by a timeout and resumed on every terminal navigation
    /// outcome, so a stuck render can never hang the caller.
    @MainActor
    private static func rasterizeImage(svg: String, side: CGFloat) async -> UIImage? {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        web.isOpaque = true
        web.backgroundColor = .white

        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let delegate = LoadThenSnapshot(side: side) { cont.resume(returning: $0) }
            web.navigationDelegate = delegate
            objc_setAssociatedObject(web, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            web.loadHTMLString(html(for: svg), baseURL: nil)
            Task {                       // hard timeout backstop
                try? await Task.sleep(for: .seconds(4))
                delegate.timeout(web)
            }
        }
    }

    /// Fallback QR from a raw payload string (unused while UCB gives us SVG).
    static func generate(from string: String, side: CGFloat = 480) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private nonisolated(unsafe) static var delegateKey: UInt8 = 0

    /// Loads the SVG, gives it a beat to lay out, then snapshots to a UIImage.
    /// Every terminal path (finish, any failure, content-process crash, timeout)
    /// resolves the caller exactly once.
    private final class LoadThenSnapshot: NSObject, WKNavigationDelegate {
        let side: CGFloat
        private let done: (UIImage?) -> Void
        private var finished = false
        init(side: CGFloat, done: @escaping (UIImage?) -> Void) { self.side = side; self.done = done }

        private func resolve(_ image: UIImage?) {
            guard !finished else { return }
            finished = true
            done(image)
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let cfg = WKSnapshotConfiguration()
                cfg.rect = CGRect(x: 0, y: 0, width: self.side, height: self.side)
                web.takeSnapshot(with: cfg) { image, _ in self.resolve(image) }
            }
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resolve(nil) }
        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resolve(nil) }
        func webViewWebContentProcessDidTerminate(_ web: WKWebView) { resolve(nil) }
        func timeout(_ web: WKWebView) { web.stopLoading(); resolve(nil) }
    }
}

/// SwiftUI on-screen QR: the cached rasterized image on a white card. Plain
/// `Image` content — nothing live in the hierarchy, so wallet rows scroll and
/// tab switches stay smooth. `.interpolation(.none)` keeps module edges crisp
/// at any display size.
struct QRCodeView: View {
    let svg: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }
        }
        .task(id: svg) { image = await QRRender.cachedImage(svg: svg) }
    }
}
