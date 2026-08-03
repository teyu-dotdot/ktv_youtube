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

    /// Hands a whole running order to YouTube as an anonymous playlist, so it
    /// advances natively instead of the app racing its autoplay.
    func loadQueue(videoIDs: [String]) {
        guard let url = YouTubePlaylist.anonymousPlaylistURL(videoIDs: videoIDs) else { return }
        webView?.load(URLRequest(url: url))
    }

    func loadPlaylist(_ playlist: YouTubePlaylist) {
        webView?.load(URLRequest(url: playlist.watchURL))
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
        controller.addUserScript(
            WKUserScript(
                source: Self.declutterScript,
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

    /// Strips a watch page back to the player and lets it use the full width.
    ///
    /// ## Widen, never set heights
    ///
    /// An earlier version forced `height: 100%` down the container chain to
    /// fill vertically, and blanked the video. A percentage height resolves
    /// against the parent's height, so the instant one element in the real DOM
    /// isn't in the selector list the chain breaks and it computes to zero —
    /// a black pane with player controls that flash and disappear.
    ///
    /// So this only ever sets widths. The player keeps its own aspect ratio and
    /// grows taller because it got wider, which reaches the same place without
    /// depending on a DOM this code can't see. The `<video>` element is left
    /// alone entirely: YouTube sizes it in pixels to letterbox correctly, and
    /// that arithmetic is better than anything guessed from here.
    ///
    /// A synthetic resize event is dispatched afterwards because that sizing
    /// only re-runs when YouTube believes the container changed; widening it
    /// from a stylesheet doesn't tell it anything.
    ///
    /// Scoped to `/watch` behind a class on `<html>`. The same rules on search
    /// or the home page would hide what you browse with, and YouTube navigates
    /// without reloading, so the gate is re-evaluated rather than set at load.
    private static let declutterScript = """
    (function () {
      var css = [
        /* Everything that isn't the player, on a watch page only. */
        'html.ktv-watch [id*="related" i], html.ktv-watch [class*="related" i],',
        'html.ktv-watch [id*="secondary" i], html.ktv-watch [class*="secondary" i],',
        'html.ktv-watch #comments, html.ktv-watch ytd-comments,',
        'html.ktv-watch #meta, html.ktv-watch #below, html.ktv-watch #info,',
        'html.ktv-watch ytd-watch-metadata,',
        'html.ktv-watch ytm-slim-video-metadata-section-renderer,',
        'html.ktv-watch ytm-video-description-header-renderer,',
        'html.ktv-watch ytm-comments-entry-point-header-renderer,',
        'html.ktv-watch .slim-video-information-container,',
        'html.ktv-watch #masthead, html.ktv-watch ytd-masthead,',
        'html.ktv-watch ytm-mobile-topbar-renderer { display: none !important; }',

        /* Width only. Heights are deliberately untouched — see the note above. */
        'html.ktv-watch #columns, html.ktv-watch #primary,',
        'html.ktv-watch #primary-inner, html.ktv-watch ytd-watch-flexy,',
        'html.ktv-watch ytm-watch, html.ktv-watch .watch-content,',
        'html.ktv-watch #player, html.ktv-watch #player-container,',
        'html.ktv-watch #player-container-outer,',
        'html.ktv-watch #player-container-inner,',
        'html.ktv-watch .player-container {',
        '  width: 100% !important; max-width: none !important;',
        '  min-width: 0 !important; margin: 0 !important; padding: 0 !important; }',

        'html.ktv-watch body { margin: 0 !important; background: #000 !important; }'
      ].join('\\n');

      function injectCSS() {
        if (document.getElementById('ktv-declutter')) { return; }
        var style = document.createElement('style');
        style.id = 'ktv-declutter';
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      }

      // Only strip watch pages; browsing needs its chrome.
      var wasWatching = null;
      function applyMode() {
        var watching = location.pathname.indexOf('/watch') === 0;
        document.documentElement.classList.toggle('ktv-watch', watching);
        if (watching !== wasWatching) {
          wasWatching = watching;
          nudgeLayout();
        }
      }

      // The player only re-fits the video when it thinks its container moved,
      // and a stylesheet widening it says nothing. This does.
      function nudgeLayout() {
        try { window.dispatchEvent(new Event('resize')); } catch (e) {}
      }

      // Autoplay lives behind a toggle whose markup differs by layout, so try
      // every form and click only the ones reporting themselves on.
      function disableAutoplay() {
        var toggles = document.querySelectorAll(
          '.ytp-autonav-toggle-button, ytm-autonav-toggle button, ' +
          'button[aria-label*="Autoplay"], button[aria-label*="自動再生"]'
        );
        for (var i = 0; i < toggles.length; i++) {
          var t = toggles[i];
          var on = t.getAttribute('aria-checked') === 'true'
                || t.getAttribute('aria-pressed') === 'true';
          if (on) { t.click(); }
        }
      }

      function tick() { injectCSS(); applyMode(); disableAutoplay(); }
      tick();
      // YouTube lays out after its own scripts settle and navigates without
      // reloading, so this keeps running rather than firing once.
      setInterval(tick, 1000);
      // A few nudges early on, while the player is still being built.
      [400, 1200, 2500].forEach(function (delay) {
        setTimeout(nudgeLayout, delay);
      });
    })();
    """

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
