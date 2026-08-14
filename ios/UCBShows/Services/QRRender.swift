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
    /// Bounded by a timeout and resumed on every terminal navigation outcome, so
    /// a stuck render can never hang the caller (geofence arming).
    @MainActor
    static func rasterize(svg: String, side: CGFloat = 480) async -> Data? {
        guard !svg.isEmpty else { return nil }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        web.isOpaque = true
        web.backgroundColor = .white

        let image: UIImage? = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let delegate = LoadThenSnapshot(side: side) { cont.resume(returning: $0) }
            web.navigationDelegate = delegate
            objc_setAssociatedObject(web, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            web.loadHTMLString(html(for: svg), baseURL: nil)
            Task {                       // hard timeout backstop
                try? await Task.sleep(for: .seconds(4))
                delegate.timeout(web)
            }
        }
        return image?.pngData()
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

/// SwiftUI on-screen QR: the SVG rendered in a WebView on a white card. Used on
/// the ticket detail screen (which also cranks brightness). Reloads only when
/// the SVG actually changes, so unrelated SwiftUI updates don't flash the code.
struct QRCodeView: UIViewRepresentable {
    let svg: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedSVG != svg else { return }
        context.coordinator.loadedSVG = svg
        web.loadHTMLString(QRRender.svgHTML(svg), baseURL: nil)
    }

    /// Tracks the loaded SVG so unrelated SwiftUI updates don't reload — and
    /// re-runs the load if WebKit's content process is reclaimed while the app
    /// is suspended (loadHTMLString pages don't auto-restore, so without this
    /// the user would arrive at the door to a blank white card).
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedSVG: String?
        func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
            guard let svg = loadedSVG else { return }
            web.loadHTMLString(QRRender.svgHTML(svg), baseURL: nil)
        }
    }
}

extension QRRender {
    static func svgHTML(_ svg: String) -> String { html(for: svg) }
}
