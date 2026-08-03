import SwiftUI
import KaraokeKit

/// The shared queue everyone at the party adds to.
///
/// Backed by a YouTube collaborative playlist rather than anything this app
/// runs. That means no accounts, no server, no sync protocol, and no app to
/// install for the people adding songs — they use the YouTube app they already
/// have, on the phone already in their hand. The iPad just reads the list back.
struct SharedPlaylistView: View {
    @Environment(AppModel.self) private var model

    @State private var linkInput = ""
    @State private var showsSetupHelp = false

    var body: some View {
        Group {
            if model.sharedPlaylist == nil {
                setup
            } else {
                playlist
            }
        }
    }

    // MARK: - Before a playlist is set

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Share one queue", systemImage: "person.2.fill")
                    .font(.headline)

                Text("Everyone adds songs from the YouTube app on their own "
                     + "phone. They show up here, and this iPad plays them in "
                     + "order.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Paste playlist link", text: $linkInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(apply)

                Button("Use this playlist", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(YouTubePlaylist.parse(linkInput) == nil)

                if !linkInput.isEmpty && YouTubePlaylist.parse(linkInput) == nil {
                    Text("That doesn't look like a playlist link. They contain "
                         + "list= followed by an id starting with PL.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                DisclosureGroup("How to make one", isExpanded: $showsSetupHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        setupStep(1, "In the YouTube app, make a playlist and set it to Unlisted or Public.")
                        setupStep(2, "Open it, tap Edit, then turn on Collaborate.")
                        setupStep(3, "Share that link with everyone, and paste it here.")
                        Text("Unlisted is enough — the app can't read a private "
                             + "playlist, and neither can your friends.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
            .padding(16)
        }
    }

    /// Accepts the pasted link. `setSharedPlaylist` rejects anything that
    /// isn't a playlist, and the field's own validation message already
    /// explains that, so a false result just leaves the text in place.
    private func apply() {
        if model.setSharedPlaylist(linkInput) {
            linkInput = ""
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - With a playlist

    @ViewBuilder
    private var playlist: some View {
        List {
            if let error = model.playlistError {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let playlist = model.sharedPlaylist {
                        Button {
                            model.playSharedPlaylistInYouTube()
                        } label: {
                            Label("Play in YouTube", systemImage: "play.rectangle")
                        }
                        ShareLink(item: playlist.pageURL) {
                            Label("Share the link", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }

            Section {
                if model.sharedPlaylistTracks.isEmpty && model.playlistError == nil {
                    Text(model.isRefreshingPlaylist
                         ? "Reading the playlist…"
                         : "Nothing on the playlist yet. Add a song from the "
                           + "YouTube app and pull down to refresh.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.sharedPlaylistTracks.enumerated()), id: \.element.id) { index, result in
                        Button {
                            Task { await model.playSharedPlaylist(from: index) }
                        } label: {
                            SharedPlaylistRow(result: result, position: index + 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("On the playlist")
                    Spacer()
                    if model.isRefreshingPlaylist {
                        ProgressView().controlSize(.mini)
                    }
                }
            }

            Section {
                if let playlist = model.sharedPlaylist {
                    ShareLink(item: playlist.pageURL) {
                        Label("Invite people", systemImage: "square.and.arrow.up")
                    }
                    Link(destination: playlist.pageURL) {
                        Label("Open playlist in YouTube", systemImage: "arrow.up.forward.app")
                    }
                }
                Button(role: .destructive) {
                    model.clearSharedPlaylist()
                    linkInput = ""
                } label: {
                    Label("Stop using this playlist", systemImage: "xmark.circle")
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refreshSharedPlaylist() }
        .task {
            if model.sharedPlaylistTracks.isEmpty { await model.refreshSharedPlaylist() }
        }
    }
}

private struct SharedPlaylistRow: View {
    let result: KaraokeSearchResult
    let position: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)

            Artwork(url: result.thumbnailURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !result.channel.isEmpty {
                    Text(result.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
