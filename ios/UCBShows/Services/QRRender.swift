import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WebKit

/// Renders UCB ticket QR codes. UCB serves each QR as inline vector SVG, so the
/// on-screen surface renders that SVG directly (crisp at any size, offline);
/// the notification attachment rasterizes it to a PNG. A CoreImage path covers
/// the case where we hold a raw payload string instead of SVG.
enum QRRender {

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

    /// Rasterize QR SVG markup to a square PNG (for notification attachments).
    @MainActor
    static func rasterize(svg: String, side: CGFloat = 480) async -> Data? {
        guard !svg.isEmpty else { return nil }
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: side, height: side), configuration: config)
        web.isOpaque = true
        web.backgroundColor = .white

        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let delegate = LoadThenSnapshot(side: side) { image in
                cont.resume(returning: image?.pngData())
            }
            web.navigationDelegate = delegate
            objc_setAssociatedObject(web, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            web.loadHTMLString(html(for: svg), baseURL: nil)
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
    private final class LoadThenSnapshot: NSObject, WKNavigationDelegate {
        let side: CGFloat
        let done: (UIImage?) -> Void
        private var finished = false
        init(side: CGFloat, done: @escaping (UIImage?) -> Void) { self.side = side; self.done = done }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let cfg = WKSnapshotConfiguration()
                cfg.rect = CGRect(x: 0, y: 0, width: self.side, height: self.side)
                web.takeSnapshot(with: cfg) { image, _ in self.done(image) }
            }
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !finished { finished = true; done(nil) }
        }
    }
}

/// SwiftUI on-screen QR: the SVG rendered in a WebView on a white card. Used on
/// the ticket detail screen (which also cranks brightness).
struct QRCodeView: UIViewRepresentable {
    let svg: String

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(QRRender.svgHTML(svg), baseURL: nil)
    }
}

extension QRRender {
    static func svgHTML(_ svg: String) -> String { html(for: svg) }
}
