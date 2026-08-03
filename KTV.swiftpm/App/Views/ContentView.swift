import SwiftUI
import KaraokeKit

/// The whole app: a full-screen YouTube player with a small floating bar.
///
/// There is no sidebar, no library and no queue view. The playlist is the
/// running order, YouTube advances through it, and everything this app adds is
/// the one thing YouTube can't do — choosing which stereo channel to play, so a
/// karaoke track with a guide vocal on one side can be sung over.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var browser = YouTubeBrowserModel()
    @State private var isAskingForSearch = false
    @State private var searchQuery = ""

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            YouTubeBrowserView(
                model: browser,
                initialVideoID: nil,
                initialPlaylist: model.playlist,
                pageTweaksEnabled: model.pageTweaksEnabled
            )
            // Both settings are read when the web view is built, so changing
            // either has to build a new one.
            .id(model.pageTweaksEnabled)
            .ignoresSafeArea()

            floatingBar
        }
        .statusBarHidden()
        .onAppear {
            browser.onEnded = { playlistReachedEnd() }
            // A karaoke night is long gaps of nobody touching the iPad. Video
            // playback usually holds the screen awake on its own, but not
            // reliably from inside a web view.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsSheet()
        }
        .alert("Search YouTube", isPresented: $isAskingForSearch) {
            TextField("Song, or song plus artist", text: $searchQuery)
                .textInputAutocapitalization(.never)
            Button("Search") {
                browser.search(searchQuery)
                searchQuery = ""
            }
            Button("Cancel", role: .cancel) { searchQuery = "" }
        } message: {
            Text("Results open in the player. Sign in to YouTube and its own "
                 + "Save button adds a song straight to your playlist.")
        }
        .onChange(of: model.configuration.sharedPlaylistID) {
            if let playlist = model.playlist {
                browser.loadPlaylist(playlist)
            }
        }
    }

    /// Reloads the playlist once it runs out, so songs added while it was
    /// playing get picked up.
    ///
    /// YouTube plays the list it loaded, which is a snapshot. People add songs
    /// from their phones all evening, and without this the night ends at
    /// whatever the playlist held when it started.
    ///
    /// The delay distinguishes "the playlist is finished" from "YouTube is
    /// moving to the next song", which look identical at the moment a video
    /// ends: if the video changed on its own, there was nothing to fix.
    private func playlistReachedEnd() {
        guard let playlist = model.playlist else { return }
        let videoAtEnd = browser.currentVideoID
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard browser.currentVideoID == videoAtEnd else { return }
            browser.loadPlaylist(playlist)
        }
    }

    /// Deliberately always visible rather than tap-to-reveal: a tap belongs to
    /// YouTube's own controls, and stealing it to show ours would mean fighting
    /// the web view for every gesture.
    private var floatingBar: some View {
        HStack(spacing: 14) {
            Picker("Audio channel", selection: Binding(
                get: { model.channelMode },
                set: { newMode in
                    model.channelMode = newMode
                    browser.setChannelMode(newMode)
                }
            )) {
                ForEach(AudioChannelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)

            Divider().frame(height: 22)

            // Searching lives in YouTube's own page rather than in a panel
            // here. This is just a shortcut into it — and the way back, since
            // browsing away from the playlist is otherwise a one-way trip.
            Button {
                isAskingForSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search YouTube")

            Button {
                if let playlist = model.playlist {
                    browser.loadPlaylist(playlist)
                } else {
                    browser.loadHome()
                }
            } label: {
                Image(systemName: "list.triangle")
            }
            .accessibilityLabel(model.playlist == nil ? "YouTube home" : "Back to playlist")

            Button {
                browser.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Reload")

            Button {
                model.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 12, y: 4)
        .padding(.bottom, 22)
    }
}
