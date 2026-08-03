import SwiftUI
import KaraokeKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isShowingAddSheet = false
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibraryView(
                isShowingAddSheet: $isShowingAddSheet,
                isShowingSettings: $isShowingSettings
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            if let track = model.selectedTrack {
                PlayerView(track: track)
                    .id(track.id)
            } else {
                EmptyPlayerView(isShowingAddSheet: $isShowingAddSheet)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $isShowingAddSheet) {
            AddTrackSheet()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: model.errorBinding,
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.dismissError() }
        } message: { message in
            Text(message)
        }
    }
}

/// Shown in the detail column before anything is selected.
struct EmptyPlayerView: View {
    @Binding var isShowingAddSheet: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No song selected", systemImage: "music.mic")
        } description: {
            Text("Add a YouTube link or import an audio file, then pick it from the list to start singing.")
        } actions: {
            Button("Add a song") { isShowingAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
