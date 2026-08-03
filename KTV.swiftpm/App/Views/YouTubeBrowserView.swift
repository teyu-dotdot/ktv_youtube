import SwiftUI
import WebKit
import KaraokeKit

/// A `WKWebView` pointed at youtube.com, driven by the queue.
///
/// ## Why a browser instead of the embedded player
///
/// The IFrame Player API is the sanctioned way to put YouTube video in an app,
/// and it's what this used to do. It failed — including on channels that exist
/// to be embedded — leaving no way to tell whether the origin check, the API
/// script, the user agent or the Playgrounds sandbox was at fault.
///
/// Loading the real site sidesteps all of it. Embedding permission is a
/// restriction on *other people's apps hosting a video*; it says nothing about
/// browsing youtube.com, so videos that refuse to embed play here normally.
/// YouTube's own search comes along free, and signing in makes playlists
/// available — which for karaoke are queues by another name.
///
/// ## Keeping the queue
///
/// Cross-origin rules blocked reaching into an embedded iframe, but they don't
/// apply to a page this app loads itself: a `WKUserScript` runs in the page
/// regardless of origin. So a script watches the `<video>` element and posts
/// back when it ends, which is all the queue needs to advance.
@MainActor
@Observable
final class YouTubeBrowserModel {
    /// Video the page is currently showing, if it's a watch page.
    private(set) var currentVideoID: String?
    private(set) var canGoBack = false
    private(set) var isLoading = false
    /// Page title, for the "add this" button to name what it's adding.
    private(set) var pageTitle: String?

    /// Set by the representable once the web view exists.
    fileprivate weak var webView: WKWebView?

    /// Called when the playing video reaches its end.
    var onEnded: (() -> Void)?

    func load(videoID: String) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return }
        webView?.load(URLRequest(url: url))
    }

    func loadHome() {
        guard let url = URL(string: "https://www.youtube.com") else { return }
        webView?.load(URLRequest(url: url))
    }

    func search(_ query: String) {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.youtube.com/results?search_query=\(escaped)")
        else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }

    fileprivate func update(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        isLoading = webView.isLoading
        pageTitle = webView.title
        // YouTubeLink already knows every URL form YouTube uses.
        currentVideoID = webView.url
            .flatMap { YouTubeLink.parse($0.absoluteString) }?
            .videoID
    }
}

struct YouTubeBrowserView: UIViewRepresentable {
    let model: YouTubeBrowserModel
    /// Video to show on first load. Later changes come through the model.
    let initialVideoID: String?

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)
        controller.addUserScript(
            WKUserScript(
                source: Self.endOfVideoScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Without this the video goes fullscreen instead of sitting in the
        // layout above the queue.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // A persistent store on purpose: signing in to YouTube makes your own
        // playlists reachable, and re-entering a password every launch would
        // make that useless.
        configuration.websiteDataStore = .default()
        // The phone layout is built for touch and keeps the player inline.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        context.coordinator.observe(webView)
        model.webView = webView

        if let initialVideoID,
           let url = URL(string: "https://www.youtube.com/watch?v=\(initialVideoID)") {
            webView.load(URLRequest(url: url))
        } else if let url = URL(string: "https://www.youtube.com") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        model.webView = webView
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.messageName)
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "ktv"

        var model: YouTubeBrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: YouTubeBrowserModel) {
            self.model = model
        }

        func observe(_ webView: WKWebView) {
            // The page is a single-page app, so navigation delegate callbacks
            // alone miss most video changes; watching the URL catches them.
            observations = [
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.model.update(from: webView) }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.model.update(from: webView) }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.model.update(from: webView) }
                },
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.model.update(from: webView) }
                }
            ]
        }

        func stopObserving() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  body["event"] as? String == "ended" else { return }
            model.onEnded?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.update(from: webView)
        }
    }

    /// Watches the page's video element and reports when it finishes.
    ///
    /// Re-attaching on a timer rather than once: YouTube is a single-page app
    /// and replaces the `<video>` element as you move between videos, so a
    /// listener bound at load time stops firing after the first song. The flag
    /// on the element keeps duplicate listeners off the same node.
    private static let endOfVideoScript = """
    (function () {
      function post(payload) {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ktv) {
          window.webkit.messageHandlers.ktv.postMessage(payload);
        }
      }
      function attach() {
        var video = document.querySelector('video');
        if (!video || video.__ktvHooked) { return; }
        video.__ktvHooked = true;
        video.addEventListener('ended', function () {
          post({ event: 'ended' });
        });
      }
      attach();
      setInterval(attach, 1000);
    })();
    """
}
