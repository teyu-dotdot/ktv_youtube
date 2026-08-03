import SwiftUI
import KaraokeKit

/// The only settings screen: which playlist to play, and the API key.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var playlistInput = ""
    @State private var apiKey = ""
    @State private var isScanning = false
    @State private var scanRejected = false

    private var parsedPlaylist: YouTubePlaylist? { YouTubePlaylist.parse(playlistInput) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let playlist = model.playlist {
                        LabeledContent("Playing", value: playlist.listID)
                            .font(.system(.subheadline, design: .monospaced))
                        ShareLink(item: playlist.pageURL) {
                            Label("Share this playlist", systemImage: "square.and.arrow.up")
                        }
                        Link(destination: playlist.pageURL) {
                            Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                        }
                    }

                    TextField("Paste playlist link", text: $playlistInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan a QR code", systemImage: "qrcode.viewfinder")
                    }

                    Button("Use this playlist") {
                        if model.setPlaylist(playlistInput) { playlistInput = "" }
                    }
                    .disabled(parsedPlaylist == nil)

                    if model.playlist != nil {
                        Button(role: .destructive) {
                            model.clearPlaylist()
                        } label: {
                            Text("Stop using this playlist")
                        }
                    }
                } header: {
                    Text("Playlist")
                } footer: {
                    if !playlistInput.isEmpty && parsedPlaylist == nil {
                        Text("That doesn't look like a playlist link — they contain "
                             + "list= followed by an id starting with PL.")
                            .foregroundStyle(.red)
                    } else {
                        Text("""
                        Make the playlist collaborative in the YouTube app \
                        (playlist ▸ Edit ▸ Collaborate) and everyone can add \
                        songs from their own phone. Unlisted is enough; a \
                        private playlist can't be opened by anyone else.

                        Scanning is the quick way in: share the playlist from a \
                        phone, show the QR code, point the iPad at it.
                        """)
                    }
                }

                Section {
                    SecureField("AIza…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("YouTube API key")
                } footer: {
                    Text("""
                    Nothing currently uses this — playback and playlists both \
                    work without it. It's kept for reading a playlist's contents \
                    back into the app, which needs the key.
                    """)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.pageTweaksEnabled },
                        set: { model.pageTweaksEnabled = $0 }
                    )) {
                        Text("Hide YouTube's page chrome")
                    }
                } footer: {
                    Text("""
                    Strips the header and comments so only the player shows. \
                    Off by default: an earlier version of this hid the container \
                    the player was built into and left a black screen. That's \
                    fixed, but reload if anything looks wrong.
                    """)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var configuration = model.configuration
                        configuration.youTubeAPIKey = apiKey
                        model.configuration = configuration
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isScanning) {
                QRScannerSheet { scanned in
                    // A QR code can hold anything; only a playlist counts.
                    if !model.setPlaylist(scanned) {
                        playlistInput = scanned
                        scanRejected = true
                    }
                }
            }
            .alert("That code isn't a playlist", isPresented: $scanRejected) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The scanned code has been put in the field above so you "
                     + "can see what it was.")
            }
            .onAppear { apiKey = model.configuration.youTubeAPIKey }
        }
    }
}
