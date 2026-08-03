import SwiftUI
import KaraokeKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isShowingSearch = false
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibraryView(
                isShowingSearch: $isShowingSearch,
                isShowingSettings: $isShowingSettings
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $isShowingSearch) {
            KaraokeSearchSheet()
        }
        .sheet(isPresented: $model.isShowingAddOriginal) {
            AddTrackSheet(initialQuery: model.pendingOriginalQuery ?? "")
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

    @ViewBuilder
    private var detail: some View {
        if let track = model.selectedTrack {
            // Karaoke videos play in YouTube's embedded player untouched;
            // everything else goes through the local engine and the separator.
            if track.source.playsInEmbeddedPlayer {
                KaraokeVideoPlayerView(track: track)
                    .id(track.id)
            } else {
                PlayerView(track: track)
                    .id(track.id)
            }
        } else {
            EmptyPlayerView(isShowingSearch: $isShowingSearch)
        }
    }
}

/// Shown in the detail column before anything is selected.
struct EmptyPlayerView: View {
    @Binding var isShowingSearch: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Nothing playing", systemImage: "music.mic")
        } description: {
            Text("Search for a song to find its karaoke version, then pick it "
                 + "from the list to start singing.")
        } actions: {
            Button("Find a song") { isShowingSearch = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
