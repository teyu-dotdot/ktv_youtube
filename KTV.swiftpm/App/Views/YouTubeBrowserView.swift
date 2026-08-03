import SwiftUI
import WebKit
import KaraokeKit

/// Which half of the stereo pair to send to both ears.
///
/// Karaoke uploads often carry a guide vocal on one channel and the bare
/// instrumental on the other; which one varies by uploader, so this is a
/// three-way switch rather than a "vocals off" button.
enum AudioChannelMode: String, CaseIterable, Identifiable {
    case both, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Stereo"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

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

    /// Latest report from the injected script. Surfaced in the player's menu so
    /// a screenshot can settle what the page actually looks like, rather than
    /// another round of guessing at selectors from the outside.
    private(set) var diagnostics: [String: String] = [:]

    /// Set when the audio graph refused to build, so the UI can say why the
    /// channel buttons did nothing rather than looking broken.
    private(set) var audioRoutingError: String?

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

    /// Sends audio to one channel or both. See `channelScript`.
    func setChannelMode(_ mode: AudioChannelMode) {
        audioRoutingError = nil
        webView?.evaluateJavaScript("window.ktvSetChannelMode('\(mode.rawValue)')")
    }

    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }

    fileprivate func reportAudioRoutingError(_ message: String?) {
        audioRoutingError = "This video's audio can't be split by channel. "
            + "Tap Reload and try again. (\(message ?? "no detail"))"
    }

    fileprivate func absorbDiagnostics(_ body: [String: Any]) {
        var readable: [String: String] = [:]
        for (key, value) in body where key != "event" {
            readable[key] = String(describing: value)
        }
        diagnostics = readable
    }

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
    /// Playlist to start on, when one is configured. Takes priority over
    /// `initialVideoID`, since a playlist is the running order.
    var initialPlaylist: YouTubePlaylist? = nil
    /// When false, nothing is injected into the page at all — no hiding, no
    /// layout changes, no channel routing. Plain YouTube.
    ///
    /// This exists to settle an argument rather than to be used day to day.
    /// Debugging a page this code can't inspect turned into several rounds of
    /// guessing; being able to switch the guesses off answers "is any of this
    /// mine?" in one attempt.
    var pageTweaksEnabled: Bool = true
    /// When true, video plays in iOS's fullscreen player rather than inline.
    var playsFullscreen: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)

        // End-of-video detection is what drives the queue, so it stays even in
        // safe mode; it only listens and never changes the page.
        controller.addUserScript(
            WKUserScript(
                source: Self.endOfVideoScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        if pageTweaksEnabled {
            for source in [Self.declutterScript, Self.channelScript] {
                controller.addUserScript(
                    WKUserScript(
                        source: source,
                        injectionTime: .atDocumentEnd,
                        forMainFrameOnly: true
                    )
                )
            }
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Inline keeps the video in the layout above the queue. Fullscreen
        // hands it to the system player, which composites separately — the
        // fallback when inline renders black.
        configuration.allowsInlineMediaPlayback = !playsFullscreen
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
        // Opaque on purpose. A transparent WKWebView composites its content
        // over whatever is behind it, and hardware-decoded video sits in its
        // own layer that does not always survive that path — it renders black
        // while the page around it draws normally, and the player's controls
        // still fade in and out over the top. That matches the symptom exactly.
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        context.coordinator.observe(webView)
        model.webView = webView

        if let initialPlaylist {
            webView.load(URLRequest(url: initialPlaylist.watchURL))
        } else if let initialVideoID,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(initialVideoID)") {
            webView.load(URLRequest(url: url))
        } else if let url = URL(string: "https://www.youtube.com") {
            // No playlist set yet — land on YouTube so there's something to do.
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
                  let event = body["event"] as? String else { return }

            switch event {
            case "ended":
                model.onEnded?()
            case "diag":
                model.absorbDiagnostics(body)
            case "audioerror":
                model.reportAudioRoutingError(body["message"] as? String)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.update(from: webView)
        }
    }

    /// Strips a watch page back to the player, and never hides the player.
    ///
    /// ## Why this is JavaScript rather than a stylesheet
    ///
    /// The clutter is matched by substring — `related`, `secondary` — because
    /// YouTube renames these containers between layouts and an exact list keeps
    /// missing. But a substring match can also hit an *ancestor* of the player,
    /// and `display: none` on an ancestor takes the video with it. That failure
    /// looks identical to the page not loading: a black rectangle with controls
    /// that flash on a drag and disappear.
    ///
    /// A stylesheet can't express "unless it contains the video". This can: it
    /// walks the matches and skips any node the `<video>` element lives inside.
    /// Broad matching, with the one thing that must survive protected.
    ///
    /// Widths still come from CSS, which is safe. Heights are never set —
    /// a percentage height resolves against the parent, so one missing link in
    /// the chain computes to zero and blanks the video just as effectively.
    private static let declutterScript = """
    (function () {
      var CLUTTER = [
        '[id*="related" i]', '[class*="related" i]',
        '[id*="secondary" i]', '[class*="secondary" i]',
        '#comments', 'ytd-comments', 'ytd-watch-metadata',
        'ytm-comments-entry-point-header-renderer',
        'ytm-slim-video-metadata-section-renderer',
        'ytm-video-description-header-renderer',
        '.slim-video-information-container',
        '#masthead', 'ytd-masthead', 'ytm-mobile-topbar-renderer'
      ].join(',');

      // Width only, and only on a watch page. See the note above about heights.
      var css = [
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

      var protectedCount = 0;
      var hiddenCount = 0;
      var waitedForVideo = 0;

      function post(payload) {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ktv) {
          window.webkit.messageHandlers.ktv.postMessage(payload);
        }
      }

      function injectCSS() {
        if (document.getElementById('ktv-declutter')) { return; }
        var style = document.createElement('style');
        style.id = 'ktv-declutter';
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      }

      function isWatching() {
        return location.pathname.indexOf('/watch') === 0;
      }

      // Hide the clutter, but never anything the video lives inside.
      var hiddenNodes = [];

      function unhideAll() {
        for (var i = 0; i < hiddenNodes.length; i++) {
          hiddenNodes[i].style.removeProperty('display');
        }
        hiddenNodes = [];
        hiddenCount = 0;
      }

      function hideClutter() {
        if (!isWatching()) { unhideAll(); return; }

        var video = document.querySelector('video');

        // Nothing is hidden until the player exists, and this is the whole
        // ballgame. Before it does, there is no way to tell which containers
        // the player is about to be built inside — and hiding one stops it
        // ever being built. That failure cannot recover on its own: the check
        // that would protect the player depends on the very element that was
        // prevented from existing, so it stays null forever and the container
        // stays hidden forever. A black pane, permanently.
        if (!video) {
          waitedForVideo++;
          // If the player still hasn't appeared after a while, something else
          // is wrong and whatever is hidden isn't helping anyone see it.
          if (waitedForVideo > 6) { unhideAll(); }
          return;
        }
        waitedForVideo = 0;

        var nodes = document.querySelectorAll(CLUTTER);
        protectedCount = 0;
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          // Never hide anything the player lives inside.
          if (node.contains(video)) { protectedCount++; continue; }
          if (node.style.display !== 'none') {
            node.style.setProperty('display', 'none', 'important');
            hiddenNodes.push(node);
          }
        }
        hiddenCount = hiddenNodes.length;
      }

      var wasWatching = null;
      function applyMode() {
        // Gated on the player existing for the same reason the hiding is:
        // restyling containers the player hasn't been built into yet is how
        // this went wrong in the first place.
        var watching = isWatching() && !!document.querySelector('video');
        document.documentElement.classList.toggle('ktv-watch', watching);
        if (watching !== wasWatching) {
          wasWatching = watching;
          nudgeLayout();
        }
      }

      // The player re-fits its video only when it believes the container moved,
      // and widening it from a stylesheet says nothing.
      function nudgeLayout() {
        try { window.dispatchEvent(new Event('resize')); } catch (e) {}
      }

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

      // Reported so a screenshot can answer what the DOM actually looks like,
      // instead of another round of guessing at selectors.
      function reportDiagnostics() {
        var video = document.querySelector('video');
        var rect = video ? video.getBoundingClientRect() : null;
        post({
          event: 'diag',
          watching: isWatching(),
          path: location.pathname,
          hasVideo: !!video,
          videoWidth: rect ? Math.round(rect.width) : 0,
          videoHeight: rect ? Math.round(rect.height) : 0,
          videoVisible: video ? (getComputedStyle(video).display !== 'none') : false,
          paused: video ? video.paused : null,
          readyState: video ? video.readyState : null,
          hidden: hiddenCount,
          protectedAncestors: protectedCount,
          waitedForVideo: waitedForVideo,
          viewportWidth: Math.round(window.innerWidth),
          viewportHeight: Math.round(window.innerHeight)
        });
      }

      function tick() {
        injectCSS();
        applyMode();
        hideClutter();
        disableAutoplay();
        reportDiagnostics();
      }
      tick();
      setInterval(tick, 1500);
      [400, 1200, 2500].forEach(function (delay) { setTimeout(nudgeLayout, delay); });
    })();
    """

    /// Routes the page's audio to the left channel, the right channel, or both.
    ///
    /// A lot of karaoke uploads — especially Chinese and Japanese ones — carry
    /// a guide vocal on one channel and the bare instrumental on the other.
    /// Picking a channel is the 原唱/伴唱 switch every KTV machine has, and it
    /// costs nothing in quality because it isn't processing anything, just
    /// choosing which half of the stereo pair to send to both ears.
    ///
    /// ## Why this works when nothing else could reach the audio
    ///
    /// Web Audio normally refuses to touch a cross-origin media element — the
    /// output is silenced to stop pages reading audio they don't own. YouTube
    /// is the exception by accident: it feeds the player through Media Source
    /// Extensions, so the element's `src` is a `blob:` URL on youtube.com's own
    /// origin. Same-origin, so `createMediaElementSource` is allowed.
    ///
    /// ## The catch
    ///
    /// Adopting an element into an audio graph is one-way. From then on its
    /// sound only reaches the speakers through that graph, and a graph that
    /// fails is silence, not a fallback. So the graph is built lazily — picking
    /// "Both" never touches it — and Reload in the menu rebuilds the page if
    /// anything goes wrong.
    private static let channelScript = """
    (function () {
      var context = null, source = null, splitter = null, merger = null;
      var hookedVideo = null;
      var mode = 'both';

      function post(payload) {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ktv) {
          window.webkit.messageHandlers.ktv.postMessage(payload);
        }
      }

      function route() {
        if (!splitter || !merger) { return; }
        try { splitter.disconnect(); } catch (e) {}
        if (mode === 'left') {
          splitter.connect(merger, 0, 0);
          splitter.connect(merger, 0, 1);
        } else if (mode === 'right') {
          splitter.connect(merger, 1, 0);
          splitter.connect(merger, 1, 1);
        } else {
          splitter.connect(merger, 0, 0);
          splitter.connect(merger, 1, 1);
        }
      }

      function buildGraph() {
        var video = document.querySelector('video');
        if (!video) { return false; }
        if (hookedVideo === video && context) { return true; }
        try {
          if (!context) {
            var Ctor = window.AudioContext || window.webkitAudioContext;
            if (!Ctor) { return false; }
            context = new Ctor();
          }
          // An element can only be adopted once, so this must not be re-run
          // for the same element.
          source = context.createMediaElementSource(video);
          splitter = context.createChannelSplitter(2);
          merger = context.createChannelMerger(2);
          source.connect(splitter);
          merger.connect(context.destination);
          hookedVideo = video;
          route();
          return true;
        } catch (error) {
          post({ event: 'audioerror', message: String(error) });
          return false;
        }
      }

      window.ktvSetChannelMode = function (next) {
        mode = next;
        // "Both" is the untouched path: if no graph exists yet, leave it that way.
        if (mode === 'both' && !context) { return; }
        if (buildGraph()) {
          if (context && context.state === 'suspended') { context.resume(); }
          route();
        }
      };

      // YouTube swaps the video element between songs, which leaves the graph
      // pointing at an element that no longer plays. Re-adopt the new one.
      setInterval(function () {
        if (mode === 'both' && !context) { return; }
        var video = document.querySelector('video');
        if (video && video !== hookedVideo) { window.ktvSetChannelMode(mode); }
      }, 1000);
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
