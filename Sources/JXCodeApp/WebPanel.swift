import AppKit
import Foundation
import SwiftUI
import WebKit

/// An embedded web panel, used for agents whose real interface is a web app.
///
/// Jules is the case that motivated this: `jules remote new` dispatches work to
/// a cloud VM, and the place you watch it run is a dashboard. Embedding the
/// dashboard keeps dispatch and review in one window.
///
/// Known caveat, surfaced in the UI rather than hidden: Google sometimes refuses
/// OAuth sign-in from an embedded web view on the grounds that it is not a
/// "secure browser". A Safari-like user agent is set to reduce the chance, and
/// there is an "Open in Safari" escape hatch, but if sign-in is refused here the
/// CLI path (`jules login`) still works — it opens the real browser and stores
/// its credentials under the sandbox `$HOME`.
@MainActor
final class WebPanelController: NSObject, ObservableObject, Identifiable {

    let id = UUID()
    let url: URL

    @Published var title: String
    @Published var isLoading = true
    @Published var lastError: String?

    private var webView: WKWebView?

    init(title: String, url: URL) {
        self.title = title
        self.url = url
        super.init()
    }

    /// Built once and cached, so switching tabs does not reload the page and
    /// lose your session.
    func makeWebView() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        // Persistent store so a successful sign-in survives relaunch.
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        // Google is likelier to allow sign-in from something that identifies as
        // Safari than from a bare WKWebView.
        view.customUserAgent = Self.safariUserAgent

        view.load(URLRequest(url: url))
        self.webView = view
        return view
    }

    func reload() {
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }

    func goForward() { webView?.goForward() }

    func openInBrowser() {
        NSWorkspace.shared.open(url)
    }

    private static var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/17.0 Safari/605.1.15"
    }
}

extension WebPanelController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        lastError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            title = pageTitle
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        lastError = error.localizedDescription
    }
}

extension WebPanelController: WKUIDelegate {
    /// Without this, OAuth popups are silently dropped and sign-in appears to do
    /// nothing. Loading the request in the same view is the standard fix.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// SwiftUI wrapper.
struct WebPanel: NSViewRepresentable {
    @ObservedObject var controller: WebPanelController

    func makeNSView(context: Context) -> WKWebView {
        controller.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
