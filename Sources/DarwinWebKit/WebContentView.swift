import SwiftUI
import WebKit

/// What a `WebView` node shows: the web view of the page whose
/// `identifier()` it carries, or nothing once the guest released it.
///
/// The page's `WKWebView` moves into this view's container while it's
/// shown, and out of it when the node goes. The page keeps loading, its
/// history and its scroll position either way. A second node showing the
/// same page takes the web view.
struct WebContentView: View {

    let identifier: Int32

    var body: some View {
        if let page = DarwinWebContent.page(identifier) {
            PlatformWebView(page: page)
        }
    }
}

#if os(iOS)
import UIKit

private struct PlatformWebView: UIViewRepresentable {

    let page: DarwinWebContent

    func makeUIView(context: Context) -> WebContainer {
        let container = WebContainer()
        container.show(page)
        return container
    }

    func updateUIView(_ container: WebContainer, context: Context) {
        container.show(page)
    }

    static func dismantleUIView(_ container: WebContainer, coordinator: ()) {
        container.show(nil)
    }
}

final class WebContainer: UIView {

    private(set) weak var page: DarwinWebContent?

    func show(_ page: DarwinWebContent?) {
        if let old = self.page, old !== page, old.webView.superview === self {
            old.webView.removeFromSuperview()
        }
        self.page = page
        guard let webView = page?.webView, webView.superview !== self else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }
}

#elseif os(macOS)
import AppKit

private struct PlatformWebView: NSViewRepresentable {

    let page: DarwinWebContent

    func makeNSView(context: Context) -> WebContainer {
        let container = WebContainer()
        container.show(page)
        return container
    }

    func updateNSView(_ container: WebContainer, context: Context) {
        container.show(page)
    }

    static func dismantleNSView(_ container: WebContainer, coordinator: ()) {
        container.show(nil)
    }
}

final class WebContainer: NSView {

    private(set) weak var page: DarwinWebContent?

    func show(_ page: DarwinWebContent?) {
        if let old = self.page, old !== page, old.webView.superview === self {
            old.webView.removeFromSuperview()
        }
        self.page = page
        guard let webView = page?.webView, webView.superview !== self else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}
#endif
