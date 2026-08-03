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
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsSheet()
        }
        .onChange(of: model.configuration.sharedPlaylistID) {
            if let playlist = model.playlist {
                browser.loadPlaylist(playlist)
            }
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
