import SwiftUI
import KaraokeKit

/// The karaoke screen: youtube.com in a web view, driven by the queue.
///
/// Doubles as a browser on purpose. YouTube's own search is better than
/// anything this app can rank, and a video found by browsing can be dropped
/// straight into the queue — so discovery and playback are the same screen
/// rather than two.
struct KaraokeVideoPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let track: Track

    @State private var browser = YouTubeBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            YouTubeBrowserView(model: browser, initialVideoID: track.source.youTubeVideoID)
                .background(.black)

            Divider()
            controls
            Divider()
            UpNextStrip()
        }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            browser.onEnded = { model.songFinished() }
        }
        .onChange(of: track.id) {
            // The queue moved on — follow it.
            if let videoID = track.source.youTubeVideoID {
                browser.load(videoID: videoID)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                browser.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!browser.canGoBack)
            .accessibilityLabel("Back")

            Button {
                model.playPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!model.queue.hasPrevious)
            .accessibilityLabel("Previous song")

            Spacer(minLength: 0)

            addCurrentVideoButton

            Spacer(minLength: 0)

            Button {
                model.presentQueue()
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Queue")

            Button {
                model.skipToNext()
            } label: {
                Label("Skip", systemImage: "forward.end.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.queue.hasNext)
            .accessibilityLabel("Skip to next song")
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? 24 : 14)
        .padding(.vertical, 10)
    }

    /// Whatever YouTube is showing right now can be queued, which is what makes
    /// browsing useful rather than a detour.
    @ViewBuilder
    private var addCurrentVideoButton: some View {
        if let videoID = browser.currentVideoID, videoID != track.source.youTubeVideoID {
            Menu {
                Button {
                    model.queueBrowsedVideo(
                        videoID: videoID, title: browser.pageTitle, playNow: true
                    )
                } label: {
                    Label("Play now", systemImage: "play.fill")
                }
                Button {
                    model.queueBrowsedVideo(
                        videoID: videoID, title: browser.pageTitle, playNow: false
                    )
                } label: {
                    Label("Add to queue", systemImage: "text.append")
                }
            } label: {
                Label("Add this video", systemImage: "plus.circle.fill")
                    .font(.subheadline)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    browser.search(track.title)
                } label: {
                    Label("Search YouTube for this song", systemImage: "magnifyingglass")
                }
                Button {
                    browser.loadHome()
                } label: {
                    Label("Browse YouTube", systemImage: "safari")
                }
                Button {
                    browser.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Divider()
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

/// A one-line "coming up" bar, so whoever's singing can see who's next without
/// opening the queue.
struct UpNextStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.presentQueue()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)

                if let next = model.nextUpTrack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Up next")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(next.title)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                } else {
                    Text("Nothing queued")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if model.queue.hasNext {
                    Text("\(model.queue.upNext.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
