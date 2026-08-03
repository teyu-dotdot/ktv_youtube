import SwiftUI
import KaraokeKit

/// Plays a karaoke video in YouTube's own embedded player.
///
/// The app's best-quality path, and the one that needs the least machinery: the
/// instrumental is the real one the karaoke producer made, the lyrics are burned
/// into the video with proper timing, and nothing has to be downloaded, decoded
/// or analysed. The trade-off is that the audio is sealed inside WebKit — there's
/// no way to reach the samples, so no key change.
struct KaraokeVideoPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let track: Track

    var body: some View {
        VStack(spacing: 0) {
            video
            controls
            Divider()
            UpNextStrip()
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

    @ViewBuilder
    private var video: some View {
        if let videoID = track.source.youTubeVideoID {
            YouTubePlayerView(
                videoID: videoID,
                onEnded: { model.songFinished() },
                onError: { code in model.karaokeVideoFailed(code: code) }
            )
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
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if model.lastVideoErrorCode != nil {
                embedRefusedBanner
            }

            HStack(spacing: 40) {
                Button {
                    model.playPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                .disabled(!model.queue.hasPrevious)
                .accessibilityLabel("Previous song")

                Button {
                    model.skipToNext()
                } label: {
                    Label("Skip", systemImage: "forward.end.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.queue.hasNext)
                .accessibilityLabel("Skip to next song")

                Menu {
                    Button {
                        model.presentQueue()
                    } label: {
                        Label("Show queue", systemImage: "list.bullet")
                    }
                    if let url = model.currentTrackWatchURL {
                        Link(destination: url) {
                            Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                }
                .accessibilityLabel("Queue")
            }
            .padding(.top, 14)

            Label(
                "Karaoke version — the backing track is the real instrumental, "
                + "so nothing needed removing. Original key.",
                systemImage: "checkmark.seal"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, horizontalSizeClass == .regular ? 40 : 20)
            .padding(.bottom, 12)
        }
    }

    /// Shown when YouTube refuses to play the video in an embed. Common on
    /// music uploads, and nothing the app can do about it — so offer the door.
    private var embedRefusedBanner: some View {
        VStack(spacing: 8) {
            Label(
                "YouTube won't play this one inside another app.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)

            HStack(spacing: 12) {
                if let url = model.currentTrackWatchURL {
                    Link(destination: url) {
                        Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if model.queue.hasNext {
                    Button("Skip") { model.skipToNext() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, horizontalSizeClass == .regular ? 40 : 20)
        .padding(.top, 12)
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
