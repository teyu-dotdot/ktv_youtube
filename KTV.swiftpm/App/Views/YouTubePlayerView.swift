import SwiftUI
import WebKit

/// YouTube's IFrame player, wrapped so the app can tell when a song ends.
///
/// The earlier version was a bare `<iframe>`, which plays fine but is silent
/// about what it's doing — and a karaoke queue has to know when to move on. So
/// this loads the IFrame Player API instead and bridges its `onStateChange`
/// callback back into Swift through a script message handler.
///
/// Two details that matter and aren't obvious:
///
/// * The page is loaded with `youtube.com` as its base URL. The IFrame API
///   checks the embedding origin, and `about:blank` fails that check.
/// * Changing `videoID` calls `loadVideoById` on the existing player rather
///   than rebuilding the web view, so skipping to the next song doesn't flash
///   a blank rectangle.
struct YouTubePlayerView: UIViewRepresentable {
    /// Player states we act on. Mirrors YouTube's numeric codes.
    enum State: Int {
        case unstarted = -1
        case ended = 0
        case playing = 1
        case paused = 2
        case buffering = 3
        case cued = 5
    }

    let videoID: String
    /// Called when the video plays through to the end — the queue's cue to move on.
    var onEnded: () -> Void = {}
    var onStateChange: (State) -> Void = { _ in }
    /// Called when YouTube refuses to play the video at all (removed, private,
    /// or embedding disabled by the uploader).
    var onError: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Without this the video takes over the screen instead of sitting in
        // the layout next to the queue.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedVideoID != videoID else { return }

        if context.coordinator.isPlayerReady {
            // Player already up: swap the video in place.
            context.coordinator.loadedVideoID = videoID
            webView.evaluateJavaScript("loadVideo('\(videoID)');")
        } else {
            context.coordinator.loadedVideoID = videoID
            webView.loadHTMLString(
                Self.html(for: videoID),
                baseURL: URL(string: "https://www.youtube.com")
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Tear the message handler down explicitly; the user content controller
    /// holds it strongly and would otherwise outlive the view.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.messageName)
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let messageName = "ktv"

        var parent: YouTubePlayerView
        weak var webView: WKWebView?
        var loadedVideoID: String?
        private(set) var isPlayerReady = false

        init(parent: YouTubePlayerView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }

            switch event {
            case "ready":
                isPlayerReady = true
            case "state":
                guard let raw = body["state"] as? Int else { return }
                if let state = State(rawValue: raw) {
                    parent.onStateChange(state)
                    if state == .ended { parent.onEnded() }
                }
            case "error":
                parent.onError(body["code"] as? Int ?? -1)
            default:
                break
            }
        }
    }

    /// `rel=0` keeps end-of-video suggestions to the same channel, and
    /// `modestbranding=1` keeps the chrome out of the way while singing.
    private static func html(for videoID: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
          <style>
            html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
            #player { width: 100%; height: 100%; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script>
            var player;
            function send(payload) {
              window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(payload);
            }
            function loadVideo(id) {
              if (player && player.loadVideoById) { player.loadVideoById(id); }
            }
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                videoId: '\(videoID)',
                playerVars: {
                  playsinline: 1, rel: 0, modestbranding: 1, autoplay: 1, fs: 1,
                  // The page is served from a base URL of youtube.com, and the
                  // player checks that the declared origin matches. Leaving
                  // these out makes the API's origin check unreliable inside a
                  // WKWebView loaded from an HTML string.
                  enablejsapi: 1, origin: 'https://www.youtube.com'
                },
                events: {
                  onReady: function () { send({ event: 'ready' }); },
                  onStateChange: function (e) { send({ event: 'state', state: e.data }); },
                  onError: function (e) { send({ event: 'error', code: e.data }); }
                }
              });
            }
            var tag = document.createElement('script');
            tag.src = 'https://www.youtube.com/iframe_api';
            document.body.appendChild(tag);
          </script>
        </body>
        </html>
        """
    }
}
