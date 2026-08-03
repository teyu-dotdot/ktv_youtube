import SwiftUI
import WebKit
import KaraokeKit

/// Plays a karaoke video in YouTube's own embedded player.
///
/// This is the app's best-quality path, and it's the one that needs the least
/// machinery: the instrumental is the real one the karaoke producer made, the
/// lyrics are burned into the video with proper timing, and nothing has to be
/// downloaded, decoded or analysed. The trade-off is that the audio is sealed
/// inside WebKit — there's no way to reach the samples, so no key change.
struct KaraokeVideoPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let track: Track

    var body: some View {
        VStack(spacing: 0) {
            if let videoID = track.source.youTubeVideoID {
                YouTubeEmbed(videoID: videoID)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
            } else {
                ContentUnavailableView(
                    "Video unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This track is missing its video id.")
                )
            }

            details
        }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) {
                        model.delete(track)
                    } label: {
                        Label("Remove from library", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.title3.weight(.semibold))
                    if let artist = track.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Label(
                    "This is a karaoke version — the backing track is the real "
                    + "instrumental, so nothing needed removing. Sing in the "
                    + "original key.",
                    systemImage: "checkmark.seal"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(horizontalSizeClass == .regular ? 32 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A `WKWebView` hosting YouTube's IFrame player.
///
/// Loaded from an HTML string rather than by navigating to the embed URL, so
/// the page can set `playsinline` and size itself to the view. `about:blank` as
/// the base URL keeps the page in an opaque origin — it has no need to read
/// anything of ours, and shouldn't be able to.
private struct YouTubeEmbed: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the video takes over the whole screen on iPhone and
        // can't be shown alongside the rest of the UI.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Nothing here should outlive the session.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        webView.loadHTMLString(Self.html(for: videoID), baseURL: URL(string: "about:blank"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedVideoID: String?
    }

    /// `rel=0` keeps the end-of-video suggestions to the same channel, and
    /// `modestbranding=1` keeps the chrome out of the way while singing.
    private static func html(for videoID: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
          <style>
            html, body { margin: 0; padding: 0; background: #000; height: 100%; }
            iframe { border: 0; width: 100%; height: 100%; display: block; }
          </style>
        </head>
        <body>
          <iframe
            src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&rel=0&modestbranding=1"
            allow="autoplay; encrypted-media; picture-in-picture"
            allowfullscreen></iframe>
        </body>
        </html>
        """
    }
}
