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

    /// One canonical render size for the cache, in POINTS — this sizes the
    /// off-screen web view and the snapshot rect, and `takeSnapshot` renders
    /// at the device's scale on top of it. 430pt is the widest phone's full
    /// screen width, so the bitmap is ~1290px @3x (≈6.5 MB decoded): crisp
    /// everywhere the app shows it, and plenty for Vision to decode the
    /// payload for the Wallet pass. (It was 1280 *points* — ~59 MB a piece.)
    private static let renderSide: CGFloat = 430

    /// Keyed by the SVG markup itself (`NSString` equality, not a hash that
    /// could collide), bounded so drifting markup between reads can't pile up
    /// bitmaps for the life of the process.
    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 16
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// Renders in progress, so the wallet row and the pushed detail asking
    /// for the same SVG within a beat share one web view instead of two.
    @MainActor private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// The rasterized QR for this SVG, rendered on first request and cached.
    @MainActor
    static func cachedImage(svg: String) async -> UIImage? {
        guard !svg.isEmpty else { return nil }
        let key = svg as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let pending = inFlight[svg] { return await pending.value }
        let task = Task { await rasterizeImage(svg: svg, side: renderSide) }
        inFlight[svg] = task
        let image = await task.value
        inFlight[svg] = nil
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        }
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
        .wrap{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:3%}
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
    /// The render came back empty for a non-empty SVG (timeout, WebKit process
    /// gone): show the glyph rather than a blank white card.
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else if svg.isEmpty || failed {
                // QR not synced yet (or didn't render) — a placeholder, never
                // a blank card.
                Image(systemName: "qrcode")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: svg) {
            failed = false
            image = await QRRender.cachedImage(svg: svg)
            failed = image == nil && !svg.isEmpty
        }
    }
}
